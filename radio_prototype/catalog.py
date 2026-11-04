"""Read-only YouTube Music catalog; all playback still uses matched Tidal FLAC."""

from .providers import youtube_track


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


class Catalog:
    def __init__(self, providers):
        self.providers = providers

    def search(self, query, kind):
        with self.providers.lock:
            items = self.providers.yt().search(query, filter=kind, limit=30)
        convert = youtube_track if kind == "songs" else card
        return {"kind": kind, "items": [convert(item) for item in items[:30]]}

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
