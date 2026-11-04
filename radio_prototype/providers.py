import functools
import json
import logging
import threading
from copy import deepcopy

import requests
import tidalapi
from ytmusicapi import YTMusic
from ytmusicapi.continuations import get_continuation_string
from ytmusicapi.exceptions import YTMusicServerError
from ytmusicapi.models.content.enums import LikeStatus

from .config import private_write
from .matching import audio_reference, match_recording, title_key


class ProviderUnavailable(RuntimeError):
    pass


def duration_seconds(value):
    if isinstance(value, (int, float)):
        return float(value)
    if not value:
        return None
    try:
        total = 0
        for part in str(value).split(":"):
            total = total * 60 + int(part)
        return float(total)
    except ValueError:
        return None


def youtube_track(item, *, include_counterpart=True):
    track = {
        "video_id": item.get("videoId"),
        "title": item.get("title", ""),
        "artists": [x["name"] for x in item.get("artists", []) if x.get("name")],
        "album": (item.get("album") or {}).get("name"),
        "duration": duration_seconds(
            item.get("duration_seconds") or item.get("duration") or item.get("length")
        ),
        "explicit": item.get("isExplicit"),
        "isrc": item.get("isrc"),
        "video_type": item.get("videoType"),
        "artwork": next(
            (
                x["url"]
                for x in reversed(item.get("thumbnails") or item.get("thumbnail") or [])
                if x.get("url")
            ),
            None,
        ),
    }
    counterpart = item.get("counterpart")
    if include_counterpart and isinstance(counterpart, dict) and counterpart.get("videoId"):
        track["counterpart"] = youtube_track(counterpart, include_counterpart=False)
    return track


def tidal_track(track):
    title = track.name
    version = getattr(track, "version", None)
    if version and version.casefold() not in title.casefold():
        title += f" ({version})"
    return {
        "id": int(track.id),
        "title": title,
        "artists": [a.name for a in track.artists],
        "album": track.album.name,
        "duration": float(track.duration),
        "explicit": getattr(track, "explicit", None),
        "isrc": getattr(track, "isrc", None),
    }


class Providers:
    def __init__(self, settings):
        self.settings = settings
        self.lock = threading.RLock()
        self.youtube = None
        self.tidal = None
        self.pending_pkce = None
        # Provider errors can include signed media URLs or authentication responses.
        logging.getLogger("tidalapi").setLevel(logging.CRITICAL)
        logging.getLogger("urllib3").setLevel(logging.CRITICAL)

    def yt(self):
        with self.lock:
            if not self.settings.youtube_file.exists():
                raise ProviderUnavailable("Connect YouTube Music on the local setup page")
            if self.youtube is None:
                session = requests.Session()
                session.request = functools.partial(session.request, timeout=30)
                self.youtube = YTMusic(str(self.settings.youtube_file), requests_session=session)
            return self.youtube

    def td(self):
        with self.lock:
            if not self.settings.tidal_file.exists():
                raise ProviderUnavailable("Connect Tidal using PKCE on the local setup page")
            if self.tidal is None:
                session = self.new_tidal()
                if not session.load_session_from_file(self.settings.tidal_file):
                    raise ProviderUnavailable("Tidal login could not be restored; reconnect")
                if not session.is_pkce or not session.check_login():
                    raise ProviderUnavailable("A subscribed Tidal PKCE session is required")
                session.save_session_to_file(self.settings.tidal_file)
                self.tidal = session
            return self.tidal

    @staticmethod
    def new_tidal():
        session = tidalapi.Session(tidalapi.Config(quality=tidalapi.Quality.hi_res_lossless))
        session.request_session.request = functools.partial(
            session.request_session.request, timeout=30
        )
        return session

    def connect_youtube(self, headers):
        # Parse in memory and validate before replacing an existing credential file.
        import ytmusicapi

        with self.lock:
            parsed = ytmusicapi.setup(headers_raw=headers)
            auth = json.loads(parsed)
            session = requests.Session()
            session.request = functools.partial(session.request, timeout=30)
            youtube = YTMusic(auth, requests_session=session)
            youtube.get_account_info()
            private_write(self.settings.youtube_file, json.dumps(auth))
            self.youtube = youtube

    def start_pkce(self):
        with self.lock:
            self.pending_pkce = self.new_tidal()
            return self.pending_pkce.pkce_login_url()

    def finish_pkce(self, redirect):
        with self.lock:
            if self.pending_pkce is None:
                raise ValueError("Start the Tidal login first")
            session = self.pending_pkce
            tokens = session.pkce_get_auth_token(redirect)
            session.process_auth_token(tokens, is_pkce_token=True)
            if not session.check_login():
                raise ProviderUnavailable("Tidal subscription check failed")
            # Precreate with restrictive permissions before the library writes tokens.
            private_write(self.settings.tidal_file, "{}")
            session.save_session_to_file(self.settings.tidal_file)
            self.tidal = session
            self.pending_pkce = None

    def search(self, query):
        with self.lock:
            return [youtube_track(x) for x in self.yt().search(query, filter="songs", limit=20)]

    def stations(self):
        with self.lock:
            rows = self.yt().get_home(limit=12)
        result = []
        seen = set()
        for row in rows:
            for item in row.get("contents", []):
                playlist = item.get("playlistId")
                # YouTube personalized radio/mix IDs, independent of translated titles.
                if playlist and playlist.startswith("RD") and playlist not in seen:
                    seen.add(playlist)
                    result.append(
                        {
                            "id": playlist,
                            "title": item.get("title", playlist),
                            "section": row.get("title", ""),
                            "source": "signed_in_home",
                        }
                    )
        return result

    def recommendations(self, video_id=None, playlist_id=None, limit=25):
        if bool(video_id) == bool(playlist_id):
            raise ValueError("Specify either a song video_id or a personalized playlist_id")
        with self.lock:
            response = self.yt().get_watch_playlist(
                videoId=video_id,
                playlistId=playlist_id,
                limit=limit,
                radio=bool(video_id),
                shuffle=False,
            )
        tracks = [youtube_track(x) for x in response.get("tracks", []) if x.get("videoId")]
        if not tracks:
            raise ProviderUnavailable("YouTube returned no playable recommendations")
        return {
            "playlist_id": response.get("playlistId") or playlist_id,
            "seed_video_id": video_id,
            "tracks": tracks,
        }

    def watch_next(self, body, continuation=None):
        with self.lock:
            youtube = self.yt()
            request = deepcopy(body)
            if continuation:
                return youtube._send_request("next", request, get_continuation_string(continuation))
            return youtube._send_request("next", request)

    def candidates(self, source):
        with self.lock:
            session = self.td()
            if source.get("isrc"):
                try:
                    matches = session.get_tracks_by_isrc(source["isrc"])
                    if matches:
                        return [tidal_track(t) for t in matches]
                except (tidalapi.exceptions.ObjectNotFound, tidalapi.exceptions.InvalidISRC):
                    pass
            # Quoted title + principal artist prevents popular unrelated tracks crowding
            # the intended song out of Tidal's first result page. Try artist-first too.
            title = title_key(source["title"])
            artist = next(iter(source.get("artists", [])), "").replace('"', " ")
            queries = [f'"{title}" "{artist}"', f"{artist} {title}"]
            if source.get("album"):
                queries.append(f"{artist} {title} {source['album']}")
            found = {}
            for query in dict.fromkeys(queries):
                for track in session.search(query, models=[tidalapi.Track], limit=50).get(
                    "tracks", []
                ):
                    found[int(track.id)] = tidal_track(track)
                if match_recording(source, list(found.values()))["status"] == "matched":
                    break
            return list(found.values())

    @staticmethod
    def _audio_source(source, reference):
        reference = deepcopy(reference)
        # Enrichment must never discard constraints already known for this occurrence.
        for key in ("explicit", "isrc"):
            if source.get(key) is not None:
                reference[key] = source[key]
        return reference

    def match(self, original):
        """Keep recommendation identity; resolve a video's audio metadata for matching."""
        with self.lock:
            source = deepcopy(original)
            # Older saved queues discarded video type and counterpart. Recover only the
            # requested seed's metadata; never replace the station or recommendation queue.
            if not source.get("video_type") and not source.get("album"):
                tracks = (
                    self.yt()
                    .get_watch_playlist(videoId=source["video_id"], limit=1)
                    .get("tracks", [])
                )
                seed = next((t for t in tracks if t.get("videoId") == source["video_id"]), None)
                if seed:
                    fresh = youtube_track(seed)
                    for key in ("video_type", "counterpart"):
                        if fresh.get(key):
                            source[key] = fresh[key]
            counterpart = source.get("counterpart")
            if source.get("video_type") == "MUSIC_VIDEO_TYPE_OMV" and counterpart:
                if audio_reference(source, counterpart, linked=True):
                    counterpart = self._audio_source(source, counterpart)
                    result = match_recording(counterpart, self.candidates(counterpart))
                    result.update(method="youtube_counterpart", audio_source=counterpart)
                    return result

            candidates = self.candidates(source)
            result = match_recording(source, candidates)
            if source.get("video_type") != "MUSIC_VIDEO_TYPE_OMV":
                return result

            # The API does not always include the UI's song/video link. Search official
            # songs, requiring exact normalized identity and bounded video-only runtime.
            artist = next(iter(source.get("artists", [])), "")
            queries = [f"{artist} {title_key(source['title'])}"]
            for candidate in candidates:
                if audio_reference(source, candidate) and title_key(candidate["title"]):
                    query = f"{artist} {candidate['title']}"
                    if query not in queries:
                        queries.append(query)
            references = {}
            outcomes = []
            for query in queries[:2]:
                for item in self.yt().search(query, filter="songs", limit=20):
                    reference = youtube_track(item)
                    if reference["video_id"] in references or not audio_reference(
                        source, reference
                    ):
                        continue
                    references[reference["video_id"]] = reference
                    reference = self._audio_source(source, reference)
                    pool = {t["id"]: t for t in candidates}
                    pool.update({t["id"]: t for t in self.candidates(reference)})
                    resolved = match_recording(reference, list(pool.values()))
                    resolved.update(method="youtube_song_metadata", audio_source=reference)
                    outcomes.append(resolved)
                if any(o["status"] == "matched" for o in outcomes):
                    break
            matched = [o for o in outcomes if o["status"] == "matched"]
            identities = {o["track"].get("isrc") or str(o["track"]["id"]) for o in matched}
            if len(identities) == 1:
                return max(matched, key=lambda o: o["score"])
            if len(identities) > 1:
                result["status"] = "skipped"
                result["reason"] = "Ambiguous audio recordings; choose a recording correction"
            elif outcomes:
                return outcomes[0]
            return result

    def track(self, track_id):
        with self.lock:
            return tidal_track(self.td().track(track_id))

    def stream(self, track_id, quality):
        with self.lock:
            session = self.td()
            session.audio_quality = quality
            stream = session.track(track_id).get_stream()
            # Persist potentially rotated refresh tokens after every authenticated operation.
            session.save_session_to_file(self.settings.tidal_file)
            return stream

    def submit_history(self, video_id):
        with self.lock:
            youtube = self.yt()
            song = youtube.get_song(video_id)
            return youtube.add_history_item(song).status_code

    def history(self):
        with self.lock:
            youtube = self.yt()
            try:
                return youtube.get_history()
            except YTMusicServerError:
                # Pinned ytmusicapi reports None for YouTube's newer sign-in message.
                # Inspect only a read; never treat the failure as a successful write.
                from ytmusicapi.navigation import SECTION_LIST, SINGLE_COLUMN_TAB, nav

                response = youtube._send_request("browse", {"browseId": "FEmusic_history"})
                for section in nav(response, SINGLE_COLUMN_TAB + SECTION_LIST, True) or []:
                    for item in section.get("itemSectionRenderer", {}).get("contents", []):
                        message = item.get("messageRenderer", {}).get("text", {})
                        text = "".join(run.get("text", "") for run in message.get("runs", []))
                        if "sign in" in text.casefold():
                            raise ProviderUnavailable(
                                "YouTube Music requests sign-in. Reconnect YouTube on the local setup page."
                            ) from None
                raise

    def rate(self, video_id, value):
        with self.lock:
            result = self.yt().rate_song(video_id, LikeStatus(value))
            # None is allowed by ytmusicapi, and is not proof the rating was rejected.
            return result

    def set_tidal_favorite(self, track_id, favorite):
        with self.lock:
            session = self.td()
            try:
                favorites = session.user.favorites
                action = favorites.add_track if favorite else favorites.remove_track
                return action(str(track_id))
            finally:
                session.save_session_to_file(self.settings.tidal_file)

    def check_tidal_favorite(self, track_id, favorite):
        # Search the collection rather than the catalog: streaming availability and
        # favoriting are separate. A failed page read must not be treated as absence.
        offset = 0
        while True:
            with self.lock:
                tracks = self.td().user.favorites.tracks(limit=100, offset=offset)
            if any(int(track.id) == int(track_id) for track in tracks):
                return favorite
            if len(tracks) < 100:
                return not favorite
            offset += len(tracks)

    def check_rating(self, video_id, value):
        with self.lock:
            # get_watch_playlist's INDIFFERENT is explicitly ambiguous in upstream docs.
            tracks = self.yt().get_watch_playlist(videoId=video_id, limit=1).get("tracks", [])
            track = next((x for x in tracks if x.get("videoId") == video_id), {})
            return value == "LIKE" and track.get("likeStatus") == "LIKE"
