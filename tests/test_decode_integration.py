"""Generated audio only. These tests do not certify either provider or audible playback."""

import base64
import functools
import json
import shutil
import socket
import subprocess
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace

import pytest
import requests
import uvicorn
from tidalapi.media import Stream

from radio_prototype.api import create_app
from radio_prototype.config import Settings
from radio_prototype.verification import verify_decode


@pytest.fixture(scope="module")
def audio(tmp_path_factory):
    if not shutil.which("ffmpeg"):
        pytest.skip("FFmpeg is not installed")
    root = tmp_path_factory.mktemp("generated-audio")
    for name, rate, fmt in [("standard", 44100, "s16"), ("hires", 96000, "s32")]:
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                f"sine=frequency=440:duration=3:sample_rate={rate}",
                "-c:a",
                "flac",
                "-sample_fmt",
                fmt,
                str(root / f"{name}.flac"),
            ],
            check=True,
            capture_output=True,
            timeout=30,
        )
    dash = root / "dash"
    dash.mkdir()
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-i",
            str(root / "hires.flac"),
            "-c:a",
            "copy",
            "-strict",
            "-2",
            "-f",
            "dash",
            "-seg_duration",
            "1",
            "-use_timeline",
            "1",
            "-use_template",
            "1",
            "-init_seg_name",
            "init.mp4",
            "-media_seg_name",
            "seg-$Number$.m4s",
            (dash / "manifest.mpd").as_posix(),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(root)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield root, f"http://127.0.0.1:{server.server_port}"
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)


@pytest.fixture
def service(tmp_path, audio, monkeypatch, request):
    root, media_origin = audio
    upstream_get = requests.get
    observed_headers = []

    def get(url, **kwargs):
        assert url.startswith("https://audio.tidal.com/")
        assert "Authorization" not in kwargs.get("headers", {})
        observed_headers.append(kwargs.get("headers", {}))
        from urllib.parse import urlsplit

        return upstream_get(media_origin + urlsplit(url).path, **kwargs)

    monkeypatch.setattr("radio_prototype.streams.requests.get", get)

    def source(track_id, _quality):
        if track_id == 4:
            xml = (root / "dash" / "manifest.mpd").read_text(encoding="utf-8")
            xml = xml.replace(
                "<Period ", "<BaseURL>https://audio.tidal.com/dash/</BaseURL><Period ", 1
            )
            return Stream().parse(
                {
                    "trackId": track_id,
                    "audioQuality": "HI_RES_LOSSLESS",
                    "bitDepth": 24,
                    "sampleRate": 96000,
                    "manifestMimeType": "application/dash+xml",
                    "manifest": base64.b64encode(xml.encode()).decode(),
                }
            )
        hires = track_id == 2
        manifest = json.dumps(
            {
                "codecs": "FLAC",
                "encryptionType": "NONE",
                "urls": ["https://audio.tidal.com/" + ("hires.flac" if hires else "standard.flac")],
            }
        )
        return Stream().parse(
            {
                "trackId": track_id,
                "audioQuality": "HI_RES_LOSSLESS" if hires else "LOSSLESS",
                "bitDepth": 24 if hires else 16,
                "sampleRate": 96000 if hires else 44100,
                "manifestMimeType": "application/vnd.tidal.bts",
                "manifest": base64.b64encode(manifest.encode()).decode(),
            }
        )

    settings = Settings(tmp_path)
    provider = SimpleNamespace(
        stream=source,
        track=lambda track_id: {
            "id": track_id,
            "title": "Generated fixture",
            "artists": ["Test oscillator"],
            "duration": 3,
        },
    )
    embedded = getattr(request, "param", False)
    app = create_app(
        settings,
        provider,
        runtime_token=settings.device_token() if embedded else None,
        embedded=embedded,
    )
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    origin = f"http://127.0.0.1:{listener.getsockname()[1]}"
    server = uvicorn.Server(
        uvicorn.Config(app, log_level="critical", access_log=False, proxy_headers=False)
    )
    thread = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started and time.monotonic() < deadline:
        time.sleep(0.01)
    assert server.started
    yield app, settings, origin, observed_headers, root
    server.should_exit = True
    thread.join(timeout=10)
    listener.close()


@pytest.mark.parametrize("service", [False, True], indirect=True)
@pytest.mark.parametrize("track_id,hires", [(1, False), (2, True), (4, True)])
def test_real_ffmpeg_decodes_entire_authenticated_fixture(service, track_id, hires):
    app, settings, origin, _, _ = service
    stream_id, plan = app.state.streams.create(track_id)
    track = {"id": track_id, "duration": 3}
    suffix = "manifest.m3u8" if plan.kind == "hls" else "assets/0.flac"
    result = verify_decode(
        f"{origin}/api/streams/{stream_id}/{suffix}",
        settings.device_token(),
        track,
        plan,
        hires,
        app.state.store,
    )
    assert result["status"] == "passed", result
    assert result["measured"]["codec"] == "flac"
    assert result["decoded_seconds"] >= 2.99
    assert app.state.store.report()["gate"] == "blocked"


def test_preview_is_not_mistaken_for_full_track(service):
    app, settings, origin, _, _ = service
    stream_id, plan = app.state.streams.create(1)
    result = verify_decode(
        f"{origin}/api/streams/{stream_id}/assets/0.flac",
        settings.device_token(),
        {"id": 1, "duration": 180},
        plan,
        False,
        app.state.store,
    )
    assert result["status"] == "failed"
    assert "shorter than the full" in result["error"]


def test_proxy_preserves_source_bytes_and_forwards_only_range(service):
    app, settings, origin, observed, root = service
    stream_id, _ = app.state.streams.create(1)
    # Use a Session directly so the CDN-only requests.get interception is not involved.
    with requests.Session() as session:
        response = session.get(
            f"{origin}/api/streams/{stream_id}/assets/0.flac",
            headers={
                "Authorization": "Bearer " + settings.device_token(),
                "Range": "bytes=0-31",
            },
            timeout=10,
        )
    assert response.ok
    # The stdlib fixture server can ignore Range. The proxy preserves either 200 or 206.
    assert response.content == (root / "standard.flac").read_bytes()
    assert observed[-1]["Range"] == "bytes=0-31"
    assert observed[-1]["Accept-Encoding"] == "identity"


def test_player_counts_fixture_playback_without_provider_dispatch(service):
    from pathlib import Path

    from radio_prototype.playback import Client, listen

    mpv = shutil.which("mpv") or Path(".tools/mpv/mpv.exe")
    if not Path(mpv).is_file():
        pytest.skip("mpv is not installed")
    app, settings, origin, _, _ = service
    client = Client(origin, settings.device_token())
    result = listen(
        client,
        settings,
        mpv,
        tidal_id=1,
        report_activity=False,
        player_options=("--force-window=no", "--vo=null", "--ao=null"),
    )
    assert result["natural_end"]
    assert 2 <= result["seconds"] <= 3.5
    assert result["source_codec"] == "flac"
    assert app.state.store.get_occurrence(result["occurrence_id"])["listened"] >= 2
    assert app.state.store.submissions() == []


def test_embedded_quality_reads_real_flac_and_fragmented_flac_headers(audio):
    from radio_prototype.source_probe import probe_resolution

    root, _ = audio
    assert probe_resolution((root / "standard.flac").read_bytes()[:42], "direct") == (16, 44100)
    assert probe_resolution((root / "hires.flac").read_bytes()[:42], "direct") == (24, 96000)
    assert probe_resolution((root / "dash/init.mp4").read_bytes(), "hls") == (24, 96000)
    with pytest.raises(ValueError):
        probe_resolution(b"not a FLAC stream", "direct")
