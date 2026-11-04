import os
import secrets
import threading
from pathlib import Path
from typing import Literal
from uuid import UUID, uuid4

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response, StreamingResponse
from pydantic import BaseModel, Field
from starlette.middleware.trustedhost import TrustedHostMiddleware

from .autoplay import Autoplay
from .config import Settings
from .providers import Providers, ProviderUnavailable
from .reporting import Reporter
from .store import Store
from .streams import Streams, UnsupportedStream
from .verification import verify_decode


class TextInput(BaseModel):
    text: str = Field(min_length=1, max_length=200_000)


class RadioInput(BaseModel):
    video_id: str | None = Field(default=None, max_length=100)
    playlist_id: str | None = Field(default=None, max_length=200)
    limit: int = Field(default=25, ge=1, le=100)


class AutoplayInput(BaseModel):
    video_id: str | None = Field(default=None, min_length=1, max_length=100)
    cursor: UUID | None = None
    limit: int = Field(default=25, ge=1, le=100)


class QueueInput(AutoplayInput):
    mode: Literal["autoplay", "radio", "station"] = "autoplay"
    playlist_id: str | None = Field(default=None, max_length=200)


class LeaseInput(BaseModel):
    device_id: UUID
    force: bool = False
    release: bool = False


class TrackInput(BaseModel):
    tidal_id: int = Field(gt=0)


class DecodeInput(TrackInput):
    expect_hires: bool = False


class OccurrenceInput(TrackInput):
    id: UUID | None = None
    video_id: str | None = Field(default=None, max_length=100)


class EventInput(BaseModel):
    id: UUID
    occurrence_id: UUID
    seconds: float = Field(ge=0, le=5, allow_inf_nan=False)
    completed: bool = False


class RatingInput(BaseModel):
    id: UUID | None = None
    occurrence_id: UUID
    value: str
    tidal_favorite: bool | None = None


class RecordingInput(BaseModel):
    video_id: str = Field(min_length=1, max_length=100)
    title: str = Field(min_length=1, max_length=500)
    artists: list[str] = Field(min_length=1, max_length=20)
    album: str | None = None
    duration: float | None = Field(default=None, gt=0, allow_inf_nan=False)
    explicit: bool | None = None
    isrc: str | None = None
    video_type: str | None = Field(default=None, max_length=100)


class SourceInput(RecordingInput):
    counterpart: RecordingInput | None = None


class CorrectionInput(TrackInput):
    video_id: str = Field(min_length=1, max_length=100)


class PlaybackInput(BaseModel):
    occurrence_id: UUID
    seconds: float = Field(ge=0, allow_inf_nan=False)
    coverage_seconds: float = Field(ge=0, allow_inf_nan=False)
    natural_end: bool
    source_codec: str | None = None


def create_app(settings=None, providers=None):
    settings = settings or Settings.from_env()
    store = Store(settings.data / "radio.sqlite3")
    providers = providers or Providers(settings)
    streams = Streams(providers)
    reporter = Reporter(store, providers)
    autoplay = Autoplay(providers, store)
    token = settings.device_token()
    session_token = secrets.token_urlsafe(32)
    jobs = {}
    decode_lock = threading.Lock()
    app = FastAPI(
        title="Personal lossless radio",
        version="0.2.0",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=settings.allowed_hosts)
    app.state.store = store
    app.state.streams = streams
    app.state.reporter = reporter
    app.state.autoplay = autoplay

    @app.middleware("http")
    async def safe_errors(request, call_next):
        try:
            response = await call_next(request)
        except KeyError:
            response = JSONResponse({"detail": "Requested item was not found"}, status_code=404)
        except ValueError as error:
            # Avoid leaking user/provider error text, which may include credentials.
            response = JSONResponse(
                {"detail": "Invalid request", "error": type(error).__name__}, status_code=422
            )
        except (ProviderUnavailable, UnsupportedStream) as error:
            response = JSONResponse({"detail": str(error)}, status_code=503)
        except Exception as error:
            response = JSONResponse(
                {
                    "detail": "Operation failed; reconnect the account or retry a read",
                    "error": type(error).__name__,
                },
                status_code=503,
            )
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
            "connect-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'"
        )
        return response

    def authorize(request: Request):
        bearer = request.headers.get("authorization", "")
        if bearer.startswith("Bearer ") and secrets.compare_digest(bearer[7:], token):
            return
        if settings.local_setup and secrets.compare_digest(
            request.cookies.get("radio_setup", ""), session_token
        ):
            if request.method not in ("GET", "HEAD"):
                if request.headers.get("origin") != str(request.base_url).rstrip("/"):
                    raise HTTPException(403, "Same-origin request required")
            return
        raise HTTPException(401, "Device bearer token required")

    protected = [Depends(authorize)]
    dispatch_lock = threading.Lock()

    def playback_device(request: Request):
        if not store.owns_lease(request.headers.get("x-device-id", "")):
            raise HTTPException(409, "Another device is playing. Take over playback to continue.")

    def setup_only():
        if not settings.local_setup:
            raise HTTPException(404)

    @app.get("/", response_class=HTMLResponse)
    def setup(request: Request):
        setup_only()
        # Setup must never be exposed by Tailscale Serve or another reverse proxy.
        if request.client.host not in ("127.0.0.1", "::1", "testclient") or request.headers.get(
            "x-forwarded-for"
        ):
            raise HTTPException(403, "Setup is available directly on localhost only")
        response = HTMLResponse(Path(__file__).with_name("setup.html").read_text(encoding="utf-8"))
        response.set_cookie("radio_setup", session_token, httponly=True, samesite="strict")
        return response

    @app.get("/api/openapi.json", dependencies=protected)
    def schema():
        return app.openapi()

    @app.get("/api/accounts", dependencies=protected)
    def accounts():
        return {
            "youtube": {"credential_file": settings.youtube_file.exists()},
            "tidal": {"credential_file": settings.tidal_file.exists(), "required_auth": "PKCE"},
            "prototype": True,
            "recap": "unverified",
        }

    @app.post("/setup/youtube", dependencies=protected)
    def connect_youtube(body: TextInput):
        setup_only()
        providers.connect_youtube(body.text)
        return {"connected": True}

    @app.post("/setup/tidal/start", dependencies=protected)
    def tidal_start():
        setup_only()
        return {"login_url": providers.start_pkce()}

    @app.post("/setup/tidal/finish", dependencies=protected)
    def tidal_finish(body: TextInput):
        setup_only()
        providers.finish_pkce(body.text)
        return {"connected": True}

    @app.get("/api/search", dependencies=protected)
    def search(q: str):
        if not 1 <= len(q) <= 300:
            raise ValueError("Invalid query length")
        return providers.search(q)

    @app.get("/api/stations", dependencies=protected)
    def stations():
        return providers.stations()

    @app.post("/api/radio", dependencies=protected)
    def radio(body: RadioInput):
        if body.playlist_id and body.playlist_id not in {x["id"] for x in providers.stations()}:
            raise ValueError("Select a station discovered from the signed-in account")
        batch = providers.recommendations(body.video_id, body.playlist_id, body.limit)
        store.evidence(
            "song_radio" if body.video_id else "personal_mix",
            "passed",
            {
                "seed_video_id": body.video_id,
                "playlist_id": batch["playlist_id"],
                "track_count": len(batch["tracks"]),
                "continuous_batches": "not_tested",
            },
        )
        return batch

    @app.post("/api/autoplay", dependencies=protected)
    def song_autoplay(body: AutoplayInput):
        if bool(body.video_id) == bool(body.cursor):
            raise HTTPException(422, "Specify either a seed video_id or a saved Autoplay cursor")
        if body.cursor:
            if "limit" in body.model_fields_set:
                raise HTTPException(
                    422, "Page size is fixed for the session; omit limit when continuing"
                )
            return autoplay.next(str(body.cursor))
        batch = autoplay.start(body.video_id, body.limit)
        store.evidence(
            "song_autoplay",
            "passed",
            {
                "seed_video_id": body.video_id,
                "playlist_id": batch["playlist_id"],
                "session_id": batch["session_id"],
                "track_count": len(batch["tracks"]),
                "request_path": "bare_song_then_returned_autoplay_endpoint",
            },
        )
        return batch

    @app.post("/api/match", dependencies=protected)
    def match(body: SourceInput):
        source = body.model_dump()
        correction = store.correction(body.video_id)
        if correction:
            return {"status": "matched", "method": "manual", "track": providers.track(correction)}
        return providers.match(source)

    @app.post("/api/device/lease", dependencies=protected)
    def device_lease(body: LeaseInput):
        if not store.lease(str(body.device_id), body.force, body.release):
            raise HTTPException(409, "Another device is playing. Take over playback to continue.")
        return {"active": not body.release, "lease_seconds": 25}

    @app.post("/api/queues", dependencies=protected)
    def queue_page(body: QueueInput):
        if body.cursor:
            if body.model_fields_set != {"cursor"}:
                raise HTTPException(422, "Continue with cursor only")
            return autoplay.next(str(body.cursor))
        if body.mode == "autoplay":
            if not body.video_id or body.playlist_id:
                raise HTTPException(422, "Autoplay needs a song")
            return autoplay.start(body.video_id, body.limit)
        if body.mode == "radio":
            if not body.video_id or body.playlist_id:
                raise HTTPException(422, "Radio needs a song")
            return autoplay.start_radio(video_id=body.video_id, limit=body.limit)
        if (
            body.video_id
            or not body.playlist_id
            or body.playlist_id not in {s["id"] for s in providers.stations()}
        ):
            raise HTTPException(422, "Select a personalized station from the signed-in account")
        return autoplay.start_radio(playlist_id=body.playlist_id, limit=body.limit)

    @app.put("/api/corrections", dependencies=protected)
    def correction(body: CorrectionInput):
        track = providers.track(body.tidal_id)
        store.correction(body.video_id, body.tidal_id)
        return {"saved": True, "track": track}

    @app.post("/api/streams", dependencies=[*protected, Depends(playback_device)])
    def stream(body: TrackInput):
        stream_id, plan = streams.create(body.tidal_id)
        suffix = "manifest.m3u8" if plan.kind == "hls" else "assets/0.flac"
        return {"id": stream_id, "url": f"/api/streams/{stream_id}/{suffix}", **plan.public()}

    @app.get("/api/streams/{stream_id}/quality", dependencies=protected)
    def stream_quality(stream_id: UUID):
        import json
        import subprocess

        plan = streams.get(str(stream_id))
        suffix = "manifest.m3u8" if plan.kind == "hls" else "assets/0.flac"
        origin = os.environ.get("RADIO_INTERNAL_ORIGIN", "http://127.0.0.1:8765")
        options = ["-allowed_extensions", "ALL"] if plan.kind == "hls" else []
        try:
            probe = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-headers",
                    f"Authorization: Bearer {token}\r\n",
                    *options,
                    "-i",
                    f"{origin}/api/streams/{stream_id}/{suffix}",
                    "-select_streams",
                    "a:0",
                    "-show_streams",
                    "-of",
                    "json",
                ],
                capture_output=True,
                text=True,
                timeout=35,
                check=False,
            )
            source = json.loads(probe.stdout)["streams"][0]
            if probe.returncode or source.get("codec_name") != "flac":
                raise ValueError("Not verified FLAC")
            return {
                "verified": True,
                "codec": "FLAC",
                "bit_depth": int(source.get("bits_per_raw_sample") or 0),
                "sample_rate": int(source.get("sample_rate") or 0),
                "source_quality": plan.quality,
            }
        except Exception:
            return {"verified": False, "codec": "FLAC", "source_quality": plan.quality}

    @app.get("/api/streams/{stream_id}/manifest.m3u8", dependencies=protected)
    def manifest(stream_id: UUID):
        return Response(
            streams.get(str(stream_id)).hls(), media_type="application/vnd.apple.mpegurl"
        )

    @app.head(
        "/api/streams/{stream_id}/assets/{index}.{extension}",
        dependencies=protected,
        include_in_schema=False,
    )
    @app.get(
        "/api/streams/{stream_id}/assets/{index}.{extension}",
        dependencies=protected,
    )
    def asset(request: Request, stream_id: UUID, index: int, extension: str):
        if extension not in ("flac", "m4s"):
            raise KeyError("Unsupported asset type")
        upstream = streams.open_asset(str(stream_id), index, request.headers.get("range"))
        headers = {
            key: value
            for key, value in upstream.headers.items()
            if key.lower()
            in (
                "content-type",
                "content-length",
                "content-range",
                "accept-ranges",
                "etag",
                "last-modified",
            )
        }
        if request.method == "HEAD":
            upstream.close()
            return Response(status_code=upstream.status_code, headers=headers)

        def chunks():
            try:
                yield from upstream.raw.stream(128 * 1024, decode_content=False)
            finally:
                upstream.close()

        return StreamingResponse(chunks(), status_code=upstream.status_code, headers=headers)

    @app.post("/api/occurrences", dependencies=protected)
    def occurrence(body: OccurrenceInput):
        # Pairing IDs here is deliberate prototype input; use /api/match before listening.
        track = providers.track(body.tidal_id)
        return {
            "id": store.occurrence(track, body.video_id, str(body.id) if body.id else None),
            "track": track,
        }

    @app.get("/api/occurrences/{occurrence_id}", dependencies=protected)
    def get_occurrence(occurrence_id: UUID):
        return store.get_occurrence(str(occurrence_id))

    @app.post("/api/events", dependencies=protected)
    def event(body: EventInput):
        inserted = store.event(str(body.id), str(body.occurrence_id), body.seconds, body.completed)
        return {"inserted": inserted, "occurrence": store.get_occurrence(str(body.occurrence_id))}

    @app.post("/api/checks/playback", dependencies=protected)
    def playback(body: PlaybackInput):
        occurrence = store.get_occurrence(str(body.occurrence_id))
        evidence = store.report()["evidence"]
        decoded = [
            row
            for row in evidence
            if row["kind"] in ("hires_decode", "lossless_decode")
            and row["status"] == "passed"
            and row["details"].get("tidal_id") == occurrence["tidal_id"]
        ]
        verified = bool(
            decoded
            and body.natural_end
            and body.source_codec == "flac"
            and body.coverage_seconds >= occurrence["duration"] - 2
            and body.seconds >= occurrence["duration"] - 2
            and occurrence["listened"] >= body.seconds - 0.1
        )
        kind = (
            "hires_playback"
            if decoded and decoded[-1]["kind"] == "hires_decode"
            else "lossless_playback"
        )
        store.evidence(
            kind,
            "passed" if verified else "incomplete",
            body.model_dump(mode="json")
            | {
                "tidal_id": occurrence["tidal_id"],
                "decode_evidence": decoded[-1]["id"] if decoded else None,
            },
        )
        return {"verified": verified}

    @app.post("/api/ratings", dependencies=protected)
    def rating(body: RatingInput):
        store.schedule_rating(
            str(body.occurrence_id),
            body.value,
            str(body.id) if body.id else None,
            tidal_favorite=body.tidal_favorite,
        )
        return {"queued": True}

    @app.post("/api/reporting/dispatch", dependencies=protected, status_code=202)
    def dispatch():
        if dispatch_lock.acquire(blocking=False):

            def run():
                try:
                    reporter.flush()
                finally:
                    dispatch_lock.release()

            threading.Thread(target=run, daemon=True).start()
        return {"scheduled": True}

    @app.post("/api/reporting/flush", dependencies=protected)
    def flush():
        reporter.flush()
        return store.submissions()

    @app.post("/api/reporting/reconcile", dependencies=protected)
    def reconcile():
        reporter.reconcile()
        return store.submissions()

    @app.post("/api/checks/decode", dependencies=protected, status_code=202)
    def decode(body: DecodeInput, request: Request):
        if not decode_lock.acquire(blocking=False):
            raise HTTPException(409, "One decode check is already running")
        try:
            track = providers.track(body.tidal_id)
            stream_id, plan = streams.create(body.tidal_id)
        except Exception:
            decode_lock.release()
            raise
        job_id = str(uuid4())
        suffix = "manifest.m3u8" if plan.kind == "hls" else "assets/0.flac"
        # Use only the service's local origin, never an input URL supplied by a client.
        url = str(request.base_url) + f"api/streams/{stream_id}/{suffix}"
        jobs[job_id] = {"status": "running", "tidal_id": body.tidal_id}

        def run():
            try:
                jobs[job_id] = verify_decode(url, token, track, plan, body.expect_hires, store)
            finally:
                decode_lock.release()

        threading.Thread(target=run, daemon=True).start()
        return {"id": job_id, "status": "running"}

    @app.get("/api/checks/{job_id}", dependencies=protected)
    def job(job_id: UUID):
        return jobs[str(job_id)]

    @app.get("/api/report", dependencies=protected)
    def report():
        return store.report()

    return app
