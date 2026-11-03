import json
import math
import re
import threading
import time
from dataclasses import dataclass
from urllib.parse import urljoin, urlsplit
from uuid import uuid4

import requests
from defusedxml import ElementTree
from isodate import parse_duration
from tidalapi import Quality


class UnsupportedStream(RuntimeError):
    pass


def trusted_url(url):
    parsed = urlsplit(url)
    host = parsed.hostname or ""
    if (
        parsed.scheme != "https"
        or parsed.username
        or parsed.password
        or parsed.port not in (None, 443)
        or not any(
            host == domain or host.endswith("." + domain)
            for domain in ("tidal.com", "tidalhifi.com")
        )
    ):
        raise UnsupportedStream("Unrecognized Tidal media host; refused to proxy")
    return url


@dataclass
class Asset:
    url: str
    seconds: float = 0


@dataclass
class Plan:
    track_id: int
    kind: str
    quality: str
    codec: str
    reported_bits: int | None
    reported_rate: int | None
    assets: list[Asset]
    created: float = 0

    def public(self):
        return {
            "tidal_id": self.track_id,
            "kind": self.kind,
            "source_quality": self.quality,
            "codec": self.codec,
            "provider_bit_depth": self.reported_bits,
            "provider_sample_rate": self.reported_rate,
            "verification": "provider_metadata_only_until_decode",
        }

    def identity(self):
        return (
            self.kind,
            self.quality,
            self.codec,
            self.reported_bits,
            self.reported_rate,
            tuple(round(asset.seconds, 6) for asset in self.assets),
        )

    def hls(self):
        if self.kind != "hls":
            raise UnsupportedStream("This source is a direct FLAC stream")
        maximum = math.ceil(max(asset.seconds for asset in self.assets))
        lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            f"#EXT-X-TARGETDURATION:{maximum}",
            "#EXT-X-MEDIA-SEQUENCE:0",
            '#EXT-X-MAP:URI="assets/0.m4s"',
        ]
        for index, asset in enumerate(self.assets[1:], start=1):
            lines.extend([f"#EXTINF:{asset.seconds:.9f},", f"assets/{index}.m4s"])
        return "\n".join([*lines, "#EXT-X-ENDLIST", ""])


def expand_template(template, number, timestamp, representation, bandwidth):
    def substitute(match):
        key, width = match.group(1), match.group(2)
        value = {
            "Number": number,
            "Time": timestamp,
            "RepresentationID": representation,
            "Bandwidth": bandwidth,
        }[key]
        if value is None:
            raise UnsupportedStream("Incomplete DASH template")
        return str(value).zfill(int(width)) if width else str(value)

    result = re.sub(
        r"\$(Number|Time|RepresentationID|Bandwidth)(?:%0(\d+)d)?\$",
        substitute,
        template.replace("$$", "\x00"),
    )
    if "$" in result:
        raise UnsupportedStream("Unsupported DASH template token")
    return result.replace("\x00", "$")


def dash_assets(xml):
    if len(xml) > 2_000_000:
        raise UnsupportedStream("Manifest too large")
    root = ElementTree.fromstring(xml)
    for node in root.iter():
        node.tag = node.tag.rsplit("}", 1)[-1]
    if root.get("type", "static") != "static" or root.findall(".//ContentProtection"):
        raise UnsupportedStream("Encrypted or dynamic DASH is unsupported")
    periods = root.findall("Period")
    if len(periods) != 1:
        raise UnsupportedStream("Expected one audio period")
    period = periods[0]
    adaptations = period.findall("AdaptationSet")
    if len(adaptations) != 1:
        raise UnsupportedStream("Multiple adaptation sets require explicit selection")
    adaptation = adaptations[0]
    representations = adaptation.findall("Representation")
    if len(representations) != 1:
        raise UnsupportedStream("Multiple representations require explicit selection")
    rep = representations[0]
    codec = rep.get("codecs", adaptation.get("codecs", "")).casefold()
    if codec != "flac":
        raise UnsupportedStream("DASH codec is not FLAC")
    base = ""
    for node in (root, period, adaptation, rep):
        base = urljoin(base, node.findtext("BaseURL", "").strip())
    template = rep.find("SegmentTemplate")
    if template is None:
        template = adaptation.find("SegmentTemplate")
    if template is None or template.find("SegmentTimeline") is None:
        raise UnsupportedStream("Expected a bounded DASH SegmentTimeline")
    if int(template.get("presentationTimeOffset", "0")) != 0:
        raise UnsupportedStream("Nonzero presentation offsets are unsupported")
    timescale = int(template.get("timescale", "1"))
    if timescale <= 0:
        raise UnsupportedStream("Invalid DASH timescale")
    number = int(template.get("startNumber", "1"))
    representation, bandwidth = rep.get("id"), rep.get("bandwidth")
    init = expand_template(template.get("initialization", ""), number, 0, representation, bandwidth)
    if not init:
        raise UnsupportedStream("Missing initialization segment")
    assets = [Asset(trusted_url(urljoin(base, init)))]
    timeline = list(template.find("SegmentTimeline"))
    total_duration = parse_duration(period.get("duration") or root.get("mediaPresentationDuration"))
    end = total_duration.total_seconds() * timescale
    timestamp = 0
    for index, entry in enumerate(timeline):
        timestamp = int(entry.get("t", timestamp))
        duration = int(entry.get("d", "0"))
        repeat = int(entry.get("r", "0"))
        if duration <= 0 or repeat < -1:
            raise UnsupportedStream("Invalid DASH segment duration")
        if repeat == -1:
            until = float(timeline[index + 1].get("t")) if index + 1 < len(timeline) else end
            repeat = math.ceil((until - timestamp) / duration) - 1
        if repeat < 0 or len(assets) + repeat + 1 > 10000:
            raise UnsupportedStream("Invalid or excessive DASH segment count")
        for _ in range(repeat + 1):
            url = expand_template(
                template.get("media", ""), number, timestamp, representation, bandwidth
            )
            if not url or timestamp >= end:
                raise UnsupportedStream("DASH timeline exceeds track duration")
            seconds = min(duration, end - timestamp) / timescale
            assets.append(Asset(trusted_url(urljoin(base, url)), seconds))
            timestamp += duration
            number += 1
    if len(assets) < 2 or abs(sum(asset.seconds for asset in assets) - end / timescale) > 0.1:
        raise UnsupportedStream("DASH timeline does not cover the full track")
    return assets


def plan_from_stream(track_id, stream):
    quality = str(stream.audio_quality)
    if quality not in ("LOSSLESS", "HI_RES_LOSSLESS"):
        raise UnsupportedStream("Provider returned lossy quality")
    if stream.is_mpd:
        assets = dash_assets(stream.get_manifest_data())
        kind = "hls"
    elif stream.is_bts:
        manifest = json.loads(stream.get_manifest_data())
        if manifest.get("encryptionType") != "NONE" or manifest.get("keyId"):
            raise UnsupportedStream("Encrypted streams are unsupported")
        if manifest.get("codecs", "").upper() != "FLAC":
            raise UnsupportedStream("Provider returned a non-FLAC codec")
        urls = manifest.get("urls", [])
        if not urls:
            raise UnsupportedStream("No full stream URL returned")
        assets, kind = [Asset(trusted_url(urls[0]))], "direct"
    else:
        raise UnsupportedStream("Unrecognized authenticated stream format")
    bits, rate = stream.get_audio_resolution()
    return Plan(track_id, kind, quality, "FLAC", bits, rate, assets, time.monotonic())


class Streams:
    def __init__(self, providers):
        self.providers = providers
        self.plans = {}
        self.lock = threading.RLock()

    def resolve(self, track_id):
        attempts = []
        for quality in (Quality.hi_res_lossless, Quality.high_lossless):
            try:
                return plan_from_stream(track_id, self.providers.stream(track_id, quality))
            except Exception as error:
                attempts.append(type(error).__name__)
        raise UnsupportedStream("No accessible lossless source (" + ", ".join(attempts) + ")")

    def create(self, track_id):
        with self.lock:
            if len(self.plans) >= 32:
                self.plans.pop(next(iter(self.plans)))
            plan = self.resolve(track_id)
            stream_id = str(uuid4())
            self.plans[stream_id] = plan
            return stream_id, plan

    def get(self, stream_id, renew=False):
        with self.lock:
            if stream_id not in self.plans:
                raise KeyError("Stream expired locally; request a new stream")
            plan = self.plans[stream_id]
            if renew or time.monotonic() - plan.created > 240:
                renewed = self.resolve(plan.track_id)
                if renewed.identity() != plan.identity():
                    raise UnsupportedStream("Source changed during renewal; reopen the track")
                self.plans[stream_id] = plan = renewed
            return plan

    def open_asset(self, stream_id, index, range_header=None):
        for attempt in range(2):
            plan = self.get(stream_id, renew=bool(attempt))
            if not 0 <= index < len(plan.assets):
                raise KeyError("Unknown media asset")
            url = plan.assets[index].url
            headers = {"Accept-Encoding": "identity"}
            if range_header:
                if not re.fullmatch(r"bytes=(?:\d+-\d*|-\d+)", range_header):
                    raise ValueError("Only one byte range is supported")
                headers["Range"] = range_header
            # Never forward a device token or provider cookie to a CDN.
            for _ in range(4):
                response = requests.get(
                    trusted_url(url),
                    headers=headers,
                    stream=True,
                    timeout=(10, 30),
                    allow_redirects=False,
                )
                if response.status_code in (301, 302, 303, 307, 308):
                    location = response.headers.get("Location", "")
                    response.close()
                    url = trusted_url(urljoin(url, location))
                    continue
                break
            if response.status_code in (401, 403, 410) and attempt == 0:
                response.close()
                continue
            if response.status_code not in (200, 206, 416):
                response.close()
                raise UnsupportedStream(
                    "Media temporarily unavailable; reconnect using the last position"
                )
            return response
        raise UnsupportedStream("Stream renewal failed")
