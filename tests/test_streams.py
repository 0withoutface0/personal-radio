import base64
import json
from types import SimpleNamespace

import pytest
from tidalapi import Quality

from radio_prototype.streams import (
    Streams,
    UnsupportedStream,
    dash_assets,
    plan_from_stream,
    trusted_url,
)


def mpd(timeline='<S d="30" r="2"/>', **kwargs):
    return (
        """<?xml version='1.0' encoding='UTF-8'?>
    <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT9S">
      <Period><AdaptationSet mimeType="audio/mp4" contentType="audio">
        <Representation id="flac" codecs="flac" bandwidth="900000" audioSamplingRate="96000">
          <SegmentTemplate timescale="10" startNumber="7" initialization="https://audio.tidal.com/init.mp4"
             media="https://audio.tidal.com/seg-$Number%03d$-$Time$.m4s">
            <SegmentTimeline>"""
        + timeline
        + """</SegmentTimeline>
          </SegmentTemplate></Representation></AdaptationSet></Period></MPD>"""
    )


def bts(quality="LOSSLESS", codec="FLAC", encryption="NONE"):
    from tidalapi.media import Stream

    return Stream().parse(
        {
            "trackId": 1,
            "audioQuality": quality,
            "manifestMimeType": "application/vnd.tidal.bts",
            "manifest": base64.b64encode(
                json.dumps(
                    {
                        "codecs": codec,
                        "encryptionType": encryption,
                        "urls": ["https://audio.tidal.com/source.flac"],
                    }
                ).encode()
            ).decode(),
        }
    )


def test_dash_initialization_start_number_and_timestamps():
    assets = dash_assets(mpd())
    assert [x.url for x in assets] == [
        "https://audio.tidal.com/init.mp4",
        "https://audio.tidal.com/seg-007-0.m4s",
        "https://audio.tidal.com/seg-008-30.m4s",
        "https://audio.tidal.com/seg-009-60.m4s",
    ]
    assert [x.seconds for x in assets] == [0, 3, 3, 3]


def test_dash_zero_and_negative_repeats():
    assert len(dash_assets(mpd('<S d="30" r="0"/><S d="30" r="1"/>'))) == 4
    assert len(dash_assets(mpd('<S d="30" r="-1"/>'))) == 4


def test_encrypted_incomplete_and_unknown_codec_dash_rejected():
    for xml in (
        mpd()
        .replace("<AdaptationSet ", "<AdaptationSet ")
        .replace("<Representation ", "<ContentProtection/><Representation "),
        mpd('<S d="30" r="0"/>'),
        mpd().replace('codecs="flac"', 'codecs="mp4a.40.2"'),
    ):
        with pytest.raises(UnsupportedStream):
            dash_assets(xml)


@pytest.mark.parametrize(
    "url",
    [
        "http://audio.tidal.com/a",
        "https://localhost/a",
        "https://127.0.0.1/a",
        "https://tidal.com.evil.test/a",
        "https://audio.tidal.com:444/a",
        "https://user:password@audio.tidal.com/a",
    ],
)
def test_untrusted_media_hosts_rejected(url):
    with pytest.raises(UnsupportedStream):
        trusted_url(url)


@pytest.mark.parametrize(
    "stream", [bts(quality="HIGH", codec="AAC"), bts(codec="AAC"), bts(encryption="AES")]
)
def test_lossy_or_encrypted_bts_rejected(stream):
    with pytest.raises(UnsupportedStream):
        plan_from_stream(1, stream)


def test_request_hires_first_then_standard_never_lossy():
    calls = []

    def stream(track_id, quality):
        calls.append(quality)
        return bts(quality="HIGH", codec="AAC") if len(calls) == 1 else bts()

    streams = Streams(SimpleNamespace(stream=stream))
    stream_id, plan = streams.create(1)
    assert calls == [Quality.hi_res_lossless, Quality.high_lossless]
    assert plan.quality == "LOSSLESS"
    assert streams.get(stream_id) is plan


def test_renewal_refuses_source_change():
    provider = SimpleNamespace(stream=lambda *_: bts())
    streams = Streams(provider)
    stream_id, _ = streams.create(1)
    provider.stream = lambda *_: bts(quality="HI_RES_LOSSLESS")
    with pytest.raises(UnsupportedStream):
        streams.get(stream_id, renew=True)


def test_hls_has_map_and_no_exposed_cdn_urls():
    stream = SimpleNamespace(
        audio_quality="HI_RES_LOSSLESS",
        is_mpd=True,
        get_manifest_data=mpd,
        get_audio_resolution=lambda: (24, 96000),
    )
    hls = plan_from_stream(1, stream).hls()
    assert '#EXT-X-MAP:URI="assets/0.m4s"' in hls
    assert "#EXT-X-TARGETDURATION:3" in hls
    assert "audio.tidal.com" not in hls
    assert "assets/3.m4s" in hls
