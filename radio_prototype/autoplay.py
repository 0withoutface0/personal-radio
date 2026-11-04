"""Normal song playback followed by YouTube's returned Automix endpoint.

get_watch_playlist(radio=False) synthesizes a radio playlist ID, so it cannot
implement the bare-song request used here. Keep this adapter against the pinned
ytmusicapi version; all opaque provider state stays in SQLite on the server.
"""

import threading
from copy import deepcopy
from uuid import uuid4

from ytmusicapi.navigation import nav
from ytmusicapi.parsers.watch import parse_watch_playlist

from .providers import ProviderUnavailable, youtube_track

WATCH_PANEL = [
    "contents",
    "singleColumnMusicWatchNextResultsRenderer",
    "tabbedRenderer",
    "watchNextTabbedResultsRenderer",
    "tabs",
    0,
    "tabRenderer",
    "content",
    "musicQueueRenderer",
    "content",
    "playlistPanelRenderer",
]
AUTOMIX_ENDPOINT = [
    "automixPreviewVideoRenderer",
    "content",
    "automixPlaylistVideoRenderer",
    "navigationEndpoint",
    "watchPlaylistEndpoint",
]
NEXT_OPTIONS = {
    "enablePersistentPlaylistPanel": True,
    "isAudioOnly": True,
    "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
}


def panel_from_response(response, continuation=False):
    path = ["continuationContents", "playlistPanelContinuation"] if continuation else WATCH_PANEL
    panel = nav(response, path, True)
    if not isinstance(panel, dict) or not isinstance(panel.get("contents"), list):
        raise ProviderUnavailable("YouTube returned an unsupported Autoplay queue format")
    return panel


def tracks_from_panel(panel):
    try:
        return [
            youtube_track(track)
            for track in parse_watch_playlist(panel["contents"])
            if track.get("videoId")
        ]
    except (KeyError, IndexError, TypeError):
        raise ProviderUnavailable("YouTube's Autoplay track format changed") from None


def continuation_token(panel):
    for item in panel.get("continuations", []):
        for key in ("nextRadioContinuationData", "nextContinuationData"):
            token = item.get(key, {}).get("continuation")
            if isinstance(token, str) and token:
                return token
    if panel.get("continuations"):
        raise ProviderUnavailable("YouTube returned an unsupported Autoplay continuation")
    return None


class Autoplay:
    def __init__(self, providers, store):
        self.providers = providers
        self.store = store
        self.lock = threading.RLock()

    def start(self, video_id, limit=25):
        if not video_id or not 1 <= limit <= 100:
            raise ValueError("Autoplay requires a song and a page size from 1 to 100")
        with self.lock:
            body = {
                **NEXT_OPTIONS,
                "videoId": video_id,
                "watchEndpointMusicSupportedConfigs": {
                    "watchEndpointMusicConfig": {
                        "hasPersistentPlaylistPanel": True,
                        "musicVideoType": "MUSIC_VIDEO_TYPE_ATV",
                    },
                },
            }
            # Deliberately omit playlistId and radio params from normal playback.
            initial = panel_from_response(self.providers.watch_next(body))
            pending = tracks_from_panel(initial)
            if not pending or pending[0]["video_id"] != video_id:
                raise ProviderUnavailable("YouTube did not return the selected Autoplay seed song")
            endpoint = next(
                (
                    nav(item, AUTOMIX_ENDPOINT, True)
                    for item in initial["contents"]
                    if nav(item, AUTOMIX_ENDPOINT, True)
                ),
                None,
            )
            playlist_id = initial.get("playlistId")
            active = initial
            if endpoint:
                if not isinstance(endpoint, dict) or not endpoint.get("playlistId"):
                    raise ProviderUnavailable("YouTube returned an incomplete Autoplay endpoint")
                # Use returned params verbatim. Never manufacture RDAMVM or force wAEB.
                body = {**NEXT_OPTIONS, **deepcopy(endpoint)}
                active = panel_from_response(self.providers.watch_next(body))
                upcoming = tracks_from_panel(active)
                if upcoming and upcoming[0]["video_id"] == pending[-1]["video_id"]:
                    upcoming = upcoming[1:]
                pending.extend(upcoming)
                playlist_id = active.get("playlistId") or endpoint["playlistId"]
            elif not initial.get("isInfinite"):
                raise ProviderUnavailable(
                    "YouTube did not offer Autoplay for this song; radio was not substituted"
                )
            token = continuation_token(active)
            if len(pending) == 1 and not token:
                raise ProviderUnavailable("YouTube returned no upcoming Autoplay songs")
            state = {
                "mode": "autoplay",
                "session_id": str(uuid4()),
                "seed_video_id": video_id,
                "playlist_id": playlist_id,
                "limit": limit,
                "request": body,
                "pending": pending,
                "continuation": token,
            }
            cursor = str(uuid4())
            self.store.add_autoplay_page(cursor, state)
            return self.next(cursor)

    def start_radio(self, video_id=None, playlist_id=None, limit=25):
        if bool(video_id) == bool(playlist_id) or not 1 <= limit <= 100:
            raise ValueError("Specify a song or a personalized station")
        with self.lock:
            body = {**NEXT_OPTIONS, "playlistId": playlist_id or "RDAMVM" + video_id}
            if video_id:
                body.update({"videoId": video_id, "params": "wAEB"})
            panel = panel_from_response(self.providers.watch_next(body))
            tracks = tracks_from_panel(panel)
            if not tracks:
                raise ProviderUnavailable("YouTube returned no radio tracks")
            state = {
                "mode": "radio" if video_id else "station",
                "session_id": str(uuid4()),
                "seed_video_id": video_id,
                "playlist_id": panel.get("playlistId") or body["playlistId"],
                "limit": limit,
                "request": body,
                "pending": tracks,
                "continuation": continuation_token(panel),
            }
            cursor = str(uuid4())
            self.store.add_autoplay_page(cursor, state)
            return self.next(cursor)

    def start_returned(self, endpoint, mode, title, limit=25):
        """Use a home shelf's actual play/Play all target, including its params."""
        if not (endpoint.get("videoId") or endpoint.get("playlistId")):
            raise ValueError("Home playback requires a returned watch endpoint")
        if mode not in ("autoplay", "radio", "station", "queue") or not 1 <= limit <= 100:
            raise ValueError("Invalid home playback mode or page size")
        with self.lock:
            body = {**NEXT_OPTIONS, **deepcopy(endpoint)}
            panel = panel_from_response(self.providers.watch_next(body))
            tracks = tracks_from_panel(panel)
            preview = next(
                (
                    nav(x, AUTOMIX_ENDPOINT, True)
                    for x in panel["contents"]
                    if nav(x, AUTOMIX_ENDPOINT, True)
                ),
                None,
            )
            if preview and mode != "queue":
                body = {**NEXT_OPTIONS, **deepcopy(preview)}
                panel = panel_from_response(self.providers.watch_next(body))
                upcoming = tracks_from_panel(panel)
                if tracks and upcoming and tracks[-1]["video_id"] == upcoming[0]["video_id"]:
                    upcoming = upcoming[1:]
                tracks.extend(upcoming)
            if not tracks:
                raise ProviderUnavailable("YouTube returned no tracks for this home selection")
            state = {
                "mode": mode,
                "session_id": str(uuid4()),
                "seed_video_id": endpoint.get("videoId"),
                "playlist_id": panel.get("playlistId") or body.get("playlistId"),
                "limit": limit,
                "request": body,
                "pending": tracks,
                "continuation": continuation_token(panel),
            }
            cursor = str(uuid4())
            self.store.add_autoplay_page(cursor, state)
            return {**self.next(cursor), "title": title}

    def next(self, cursor):
        with self.lock:
            state, cached = self.store.autoplay_page(cursor)
            if cached is not None:
                return cached
            limit = state["limit"]
            requests = 0
            while len(state["pending"]) < limit and state["continuation"]:
                if requests >= 4:
                    raise ProviderUnavailable("Autoplay returned too few songs; retry this page")
                token = state["continuation"]
                response = self.providers.watch_next(state["request"], token)
                panel = panel_from_response(response, continuation=True)
                next_token = continuation_token(panel)
                if next_token == token:
                    raise ProviderUnavailable(
                        "YouTube repeated an Autoplay continuation; retry later"
                    )
                state["pending"].extend(tracks_from_panel(panel))
                state["continuation"] = next_token
                requests += 1
            tracks, state["pending"] = state["pending"][:limit], state["pending"][limit:]
            next_cursor = str(uuid4()) if state["pending"] or state["continuation"] else None
            response = {
                "mode": state.get("mode", "autoplay"),
                "session_id": state["session_id"],
                "seed_video_id": state["seed_video_id"],
                "playlist_id": state["playlist_id"],
                "tracks": tracks,
                "next_cursor": next_cursor,
                "has_more": next_cursor is not None,
            }
            return self.store.finish_autoplay_page(cursor, response, next_cursor, state)
