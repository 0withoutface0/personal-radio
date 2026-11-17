"""YouTube Music catalog and playlist editing. Playback uses matched Tidal audio."""

import re

from requests import RequestException
from ytmusicapi.exceptions import YTMusicError

from .providers import ProviderUnavailable, youtube_track


def artwork(item):
    return next(
        (x["url"] for x in reversed(item.get("thumbnails") or []) if x.get("url")),
        None,
    )


def card(item):
    return {
        "id": item.get("browseId"),
        "title": item.get("title") or item.get("artist") or item.get("name", ""),
        "artists": item.get("artists") or [],
        "year": item.get("year"),
        "type": item.get("type"),
        "explicit": item.get("isExplicit"),
        "artwork": artwork(item),
    }


def playlist_id(value):
    if not isinstance(value, str):
        raise ValueError("Missing playlist ID")
    value = value.removeprefix("VL")
    if not re.fullmatch(r"[A-Za-z0-9_-]{2,200}", value):
        raise ValueError("Invalid playlist ID")
    return value


def playlist_card(item, identifier=None):
    author = item.get("author") or []
    if isinstance(author, dict):
        author = [author]
    return {
        "id": playlist_id(identifier or item.get("playlistId") or item.get("browseId")),
        "title": item.get("title") or "Untitled playlist",
        "artists": author,
        "artwork": artwork(item),
        "owned": item.get("owned") is True,
    }


class PlaylistNotOwned(Exception):
    pass


class Catalog:
    def __init__(self, providers):
        self.providers = providers

    def search(self, query, kind):
        with self.providers.lock:
            items = self.providers.yt().search(query, filter=kind, limit=30)
        if kind == "playlists":
            return {"kind": kind, "items": [
                playlist_card(item) for item in items[:30]
                if item.get("playlistId") or item.get("browseId")
            ]}
        convert = youtube_track if kind == "songs" else card
        return {"kind": kind, "items": [convert(item) for item in items[:30]]}

    def playlists(self):
        with self.providers.lock:
            items = self.providers.yt().get_library_playlists(limit=None)
        return {"items": [playlist_card(item) for item in items if item.get("playlistId")]}

    def playlist(self, identifier):
        identifier = playlist_id(identifier)
        with self.providers.lock:
            item = self.providers.yt().get_playlist(identifier, limit=None)
        tracks = [
            youtube_track({**track, "artists": track.get("artists") or []})
            for track in item.get("tracks") or []
        ]
        return {**playlist_card(item, identifier), "tracks": tracks}

    def add_playlist_song(self, identifier, video_id):
        identifier = playlist_id(identifier)
        if identifier in {"LM", "LL", "SE"} or identifier.startswith(("RD", "OLA")):
            raise PlaylistNotOwned
        with self.providers.lock:
            yt = self.providers.yt()
            if yt.get_playlist(identifier, limit=1).get("owned") is not True:
                raise PlaylistNotOwned
            try:
                # This option in ytmusicapi 1.12.3 sends DEDUPE_OPTION_SKIP.
                # Use the active client in case the preceding read renewed it.
                result = self.providers.yt().add_playlist_items(
                    identifier, videoIds=[video_id], duplicates=True,
                )
            except (RequestException, YTMusicError):
                result = None
        status = result.get("status") if isinstance(result, dict) else result
        if status != "STATUS_SUCCEEDED":
            raise ProviderUnavailable(
                "YouTube Music could not confirm the change. Check the playlist before retrying."
            )
        return {"saved": True}

    def artist(self, artist_id):
        with self.providers.lock:
            item = self.providers.yt().get_artist(artist_id)
        songs = []
        for song in (item.get("songs") or {}).get("results", []):
            # Some shelves omit the repeated artist metadata.
            song = {
                **song,
                "artists": song.get("artists") or [{"name": item["name"], "id": artist_id}],
            }
            songs.append(youtube_track(song))
        return {
            "id": artist_id,
            "title": item["name"],
            "description": item.get("description"),
            "artwork": artwork(item),
            "songs": songs,
            "releases": {
                kind: [card(x) for x in (item.get(kind) or {}).get("results", [])]
                for kind in ("albums", "singles")
            },
        }

    def releases(self, artist_id, kind, limit):
        with self.providers.lock:
            yt = self.providers.yt()
            section = yt.get_artist(artist_id).get(kind) or {}
            if section.get("browseId") and section.get("params"):
                items = yt.get_artist_albums(section["browseId"], section["params"], limit=limit)
                more = len(items) >= limit
            else:
                items = section.get("results", [])
                more = False
        return {
            "items": [card(x) for x in items[:limit]],
            "limit": limit,
            "has_more": more and limit < 1000,
            "limited": more and limit == 1000,
        }

    def album(self, album_id):
        with self.providers.lock:
            item = self.providers.yt().get_album(album_id)
        album = card({**item, "browseId": album_id})
        tracks = []
        for index, track in enumerate(item.get("tracks") or []):
            source = {
                **track,
                "album": {"id": album_id, "name": item["title"]},
                "artists": track.get("artists") or item.get("artists") or [],
                "thumbnails": track.get("thumbnails") or item.get("thumbnails"),
            }
            tracks.append({**youtube_track(source), "track_number": index + 1})
        return {**album, "description": item.get("description"), "tracks": tracks}
