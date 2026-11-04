"""Signed-in home shelves, adapted against the pinned ytmusicapi response format.

YouTube calls Speed dial "Listen again" on some clients. Only these two shelves
are exposed. Playback endpoints/params remain on the server behind expiring IDs.
"""

import time
from collections import OrderedDict
from copy import deepcopy
from datetime import UTC, datetime
from uuid import uuid4

from ytmusicapi.continuations import get_continuation_string
from ytmusicapi.exceptions import YTMusicServerError
from ytmusicapi.navigation import SINGLE_COLUMN_TAB, nav
from ytmusicapi.parsers.browsing import parse_mixed_content

from .catalog import artwork
from .providers import ProviderUnavailable, youtube_track


def text(value):
    if not isinstance(value, dict):
        return ""
    return value.get("simpleText") or "".join(x.get("text", "") for x in value.get("runs", []))


def watch_target(value):
    """Read only a primary play destination, never radio/queue menu actions."""
    if not isinstance(value, dict):
        return None
    for kind in ("watchEndpoint", "watchPlaylistEndpoint"):
        endpoint = value.get(kind)
        if isinstance(endpoint, dict) and (endpoint.get("videoId") or endpoint.get("playlistId")):
            return deepcopy(endpoint)
    return None


def item_target(item):
    data = next(iter(item.values()), {})
    overlay = (
        nav(
            data,
            ["overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer"],
            True,
        )
        or {}
    )
    return watch_target(overlay.get("playNavigationEndpoint")) or watch_target(
        data.get("navigationEndpoint")
    )


class HomeFeed:
    def __init__(self, providers):
        self.providers = providers
        self.cached = None
        self.cached_at = 0
        self.identity = None
        self.targets = OrderedDict()

    def _identity(self, youtube):
        return id(youtube), self.providers.settings.youtube_file.stat().st_mtime_ns

    def _target(self, endpoint, mode, title):
        if not endpoint:
            return None
        key = str(uuid4())
        self.targets[key] = (time.monotonic() + 3600, deepcopy(endpoint), mode, title)
        while len(self.targets) > 2048:
            self.targets.popitem(last=False)
        return key

    def playback(self, selection_id):
        with self.providers.lock:
            if self.identity != self._identity(self.providers.yt()):
                self.targets.clear()
            target = self.targets.get(selection_id)
            if not target or target[0] < time.monotonic():
                raise ProviderUnavailable(
                    "Home selection expired. Refresh home and select it again."
                )
            return deepcopy(target[1]), target[2], target[3]

    def _items(self, shelf, kind):
        result = []
        for raw in (shelf.get("contents") or shelf.get("items") or [])[:100]:
            try:
                rows = parse_mixed_content([{"musicCarouselShelfRenderer": {"contents": [raw]}}])
                item = rows[0]["contents"][0]
            except (KeyError, IndexError, TypeError, StopIteration):
                continue  # Non-music renderers (ads, podcasts, placeholders).
            endpoint = item_target(raw)
            card = {"title": item.get("title", ""), "artwork": artwork(item)}
            if item.get("videoId"):
                card.update(kind="song", song=youtube_track(item))
                mode = "radio" if kind == "quick_picks" else "autoplay"
            elif (browse_id := item.get("browseId") or "").startswith("UC"):
                card.update(kind="artist", id=browse_id)
                endpoint, mode = None, None
            elif browse_id.startswith("MPRE"):
                card.update(kind="album", id=browse_id)
                endpoint, mode = None, None
            elif playlist_id := item.get("playlistId"):
                card.update(kind="playlist", id=playlist_id)
                endpoint = endpoint or {"playlistId": playlist_id}
                mode = "station" if playlist_id.startswith("RD") else "queue"
            else:
                continue
            card["play_id"] = self._target(endpoint, mode, card["title"])
            result.append(card)
        return result

    def _shelves(self, rows, sections, *, dedicated=False):
        for row in rows:
            shelf = next(iter(row.values()), {})
            header = shelf.get("header", {}).get("musicCarouselShelfBasicHeaderRenderer", {})
            title = text(header.get("title")) or text(shelf.get("title"))
            key = title.strip().casefold()
            if key in ("speed dial", "listen again") or dedicated:
                kind = "speed_dial"
            elif key == "quick picks":
                kind = "quick_picks"
            else:
                continue
            items = self._items(shelf, kind)
            if not items:
                continue
            previous = sections[kind]
            if not previous["items"] or dedicated:
                previous["items"] = items
                previous["available"] = True
                previous["message"] = None
                if kind == "quick_picks":
                    button = header.get("moreContentButton", {}).get("buttonRenderer", {})
                    previous["play_all_id"] = self._target(
                        watch_target(button.get("navigationEndpoint")), "radio", "Quick picks"
                    )

    @staticmethod
    def _section(response):
        return nav(response, SINGLE_COLUMN_TAB + ["sectionListRenderer"], True) or {}

    def snapshot(self, *, refresh=False):
        with self.providers.lock:
            youtube = self.providers.yt()
            identity = self._identity(youtube)
            if identity != self.identity:
                self.targets.clear()
                self.cached = None
                self.identity = identity
            if self.cached and not refresh and time.monotonic() - self.cached_at < 300:
                return deepcopy(self.cached)
            # get_home also returns generic shelves when browser auth expires.
            # Fail closed rather than present those as personal recommendations.
            try:
                account = youtube.get_account_info()
                if not account.get("accountName"):
                    raise KeyError("accountName")
            except (KeyError, YTMusicServerError):
                raise ProviderUnavailable(
                    "YouTube Music requests sign-in. Reconnect YouTube on the local setup page."
                ) from None
            sections = {
                key: {
                    "title": title,
                    "items": [],
                    "available": False,
                    "message": f"YouTube did not return {title} for this account. Try refreshing later.",
                }
                for key, title in (("speed_dial", "Speed dial"), ("quick_picks", "Quick picks"))
            }
            body = {"browseId": "FEmusic_home"}
            section = self._section(youtube._send_request("browse", deepcopy(body)))
            for _ in range(5):
                self._shelves(section.get("contents", []), sections)
                if all(value["available"] for value in sections.values()):
                    break
                continuation = next(
                    (
                        entry["nextContinuationData"].get("continuation")
                        for entry in section.get("continuations", [])
                        if "nextContinuationData" in entry
                    ),
                    None,
                )
                if not continuation:
                    break
                response = youtube._send_request(
                    "browse", deepcopy(body), get_continuation_string(continuation)
                )
                section = (
                    nav(response, ["continuationContents", "sectionListContinuation"], True) or {}
                )
            if not sections["speed_dial"]["available"]:
                try:
                    response = youtube._send_request("browse", {"browseId": "FEmusic_listen_again"})
                    content = nav(response, SINGLE_COLUMN_TAB, True) or {}
                    rows = content.get("sectionListRenderer", {}).get("contents") or [content]
                    self._shelves(rows, sections, dedicated=True)
                except YTMusicServerError:
                    pass  # An unavailable optional shelf does not hide Quick picks.
            self.cached = {
                **sections,
                "source": "youtube_music",
                "fetched_at": datetime.now(UTC).isoformat(),
            }
            self.cached_at = time.monotonic()
            return deepcopy(self.cached)
