import json
import os
import queue
import socket
import sqlite3
import subprocess
import threading
import time
from pathlib import Path
from uuid import uuid4

import requests


class PlaybackClock:
    """Conservative wall-time measurement driven by mpv's actual playback position."""

    BLOCKERS = {"pause", "paused-for-cache", "seeking", "core-idle", "mute"}

    def __init__(self):
        self.properties = {"core-idle": True}
        self.previous = None
        self.total = 0.0
        self.intervals = []

    def update(self, name, value, timestamp):
        self.properties[name] = value
        if any(self.properties.get(key) for key in self.BLOCKERS):
            self.previous = None
            return 0.0
        if name != "time-pos":
            return 0.0
        if value is None:
            self.previous = None
            return 0.0
        current = (float(value), timestamp)
        seconds = 0.0
        if self.previous:
            media_delta = current[0] - self.previous[0]
            wall_delta = current[1] - self.previous[1]
            if 0 < wall_delta <= 2 and 0 < media_delta <= wall_delta + 0.3:
                # Position updates are quantized. Taking min(position, wall) per tick
                # accumulates scheduler jitter into a substantial listening undercount.
                seconds = round(wall_delta, 6)
                if seconds:
                    self.intervals.append((self.previous[0], current[0]))
        self.previous = current
        self.total += seconds
        return seconds

    def coverage(self):
        merged = []
        for start, end in sorted(self.intervals):
            if merged and start <= merged[-1][1] + 0.05:
                merged[-1] = (merged[-1][0], max(merged[-1][1], end))
            else:
                merged.append((start, end))
        return sum(end - start for start, end in merged)


class Client:
    def __init__(self, base_url, token):
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {token}"

    def call(self, path, body=None, method="POST"):
        response = self.session.request(method, self.base_url + path, json=body, timeout=(5, 45))
        if not response.ok:
            # Only expose the service's redacted error message, never a request or token.
            try:
                detail = response.json().get("detail", "Request failed")
            except ValueError:
                detail = "Request failed"
            raise RuntimeError(f"HTTP {response.status_code}: {detail}")
        return response.json()


class Outbox:
    def __init__(self, path):
        self.path = path
        with sqlite3.connect(path) as db:
            db.execute(
                "CREATE TABLE IF NOT EXISTS outbox (id TEXT PRIMARY KEY, payload TEXT NOT NULL)"
            )

    def add(self, occurrence_id, seconds, completed=False):
        event = {
            "id": str(uuid4()),
            "occurrence_id": occurrence_id,
            "seconds": seconds,
            "completed": completed,
        }
        with sqlite3.connect(self.path) as db:
            db.execute("INSERT INTO outbox VALUES (?,?)", (event["id"], json.dumps(event)))

    def flush(self, client):
        with sqlite3.connect(self.path) as db:
            rows = list(db.execute("SELECT id,payload FROM outbox ORDER BY rowid"))
        for event_id, payload in rows:
            client.call("/api/events", json.loads(payload))
            # A crash between server acknowledgement and delete is safe: the ID is unchanged.
            with sqlite3.connect(self.path) as db:
                db.execute("DELETE FROM outbox WHERE id=?", (event_id,))


class IPC:
    def __init__(self, endpoint, process):
        self.socket = None
        deadline = time.monotonic() + 20
        while True:
            try:
                if os.name == "nt":
                    from .windows_pipe import WindowsPipe

                    self.pipe = WindowsPipe(endpoint)
                else:
                    self.socket = socket.socket(socket.AF_UNIX)
                    self.socket.connect(endpoint)
                    self.pipe = self.socket.makefile("rwb", buffering=0)
                break
            except OSError:
                if self.socket:
                    self.socket.close()
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Could not connect to mpv JSON IPC") from None
                time.sleep(0.1)
        self.messages = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        try:
            for line in self.pipe:
                self.messages.put((time.monotonic(), json.loads(line)))
        except (OSError, ValueError):
            pass
        finally:
            self.messages.put((time.monotonic(), {"event": "ipc-closed"}))

    def command(self, *command):
        self.pipe.write((json.dumps({"command": command}) + "\n").encode())

    def close(self):
        self.pipe.close()
        if self.socket:
            self.socket.close()


def listen(
    client,
    settings,
    mpv_path,
    tidal_id=None,
    video_id=None,
    resume=None,
    report_activity=True,
    player_options=(),
):
    """Audible prototype player. Not a replacement for the gated Flutter application."""
    lockfile = open(settings.data / "player.lock", "a+b")
    try:
        if os.name == "nt":
            import msvcrt

            lockfile.seek(0)
            lockfile.write(b"0")
            lockfile.seek(0)
            msvcrt.locking(lockfile.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            fcntl.flock(lockfile, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        lockfile.close()
        raise RuntimeError("An audible prototype player is already active") from None

    process = None
    ipc = None
    endpoint = (
        rf"\\.\pipe\personal-radio-{uuid4()}"
        if os.name == "nt"
        else str(settings.data / f"mpv-{uuid4()}.sock")
    )
    try:
        outbox = Outbox(settings.data / "client-outbox.sqlite3")
        outbox.flush(client)
        if resume:
            occurrence = client.call(f"/api/occurrences/{resume}", method="GET")
            if not report_activity and occurrence.get("video_id"):
                raise RuntimeError(
                    "This occurrence has YouTube reporting enabled; start a local-only occurrence"
                )
            occurrence_id, tidal_id = occurrence["id"], occurrence["tidal_id"]
        else:
            result = client.call("/api/occurrences", {"tidal_id": tidal_id, "video_id": video_id})
            occurrence_id = result["id"]
        stream = client.call("/api/streams", {"tidal_id": tidal_id})
        print(f"Occurrence: {occurrence_id}\nSource: {stream['source_quality']} / FLAC")
        print("Space: pause/resume · arrows: seek · q: stop. Played time excludes interruptions.")
        process = subprocess.Popen(
            [
                str(mpv_path),
                "--no-config",
                "--idle=yes",
                "--force-window=yes",
                "--no-video",
                "--audio-display=no",
                "--terminal=no",
                "--keep-open=no",
                "--speed=1",
                "--osd-level=2",
                "--title=Personal Radio — integration playback check",
                f"--input-ipc-server={endpoint}",
                *player_options,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=(
                subprocess.CREATE_NO_WINDOW
                if os.name == "nt" and "--vo=null" in player_options
                else 0
            ),
        )
        ipc = IPC(endpoint, process)
        for index, name in enumerate(
            [
                "pause",
                "paused-for-cache",
                "seeking",
                "core-idle",
                "mute",
                "time-pos",
                "duration",
                "audio-codec-name",
            ]
        ):
            ipc.command("observe_property", index + 1, name)
        # The device token does not appear in the process command line or media URL.
        ipc.command(
            "set_property",
            "http-header-fields",
            [f"Authorization: {client.session.headers['Authorization']}"],
        )
        ipc.command("loadfile", client.base_url + stream["url"])
        clock = PlaybackClock()
        natural_end = False
        stop_flush = threading.Event()
        connection_failed = threading.Event()

        def flush_loop():
            background_client = Client(client.base_url, settings.device_token())
            while not stop_flush.wait(2):
                try:
                    outbox.flush(background_client)
                    if report_activity:
                        background_client.call("/api/reporting/flush", {})
                except (requests.RequestException, RuntimeError):
                    connection_failed.set()

        flusher = threading.Thread(target=flush_loop, daemon=True)
        flusher.start()
        while process.poll() is None:
            try:
                timestamp, message = ipc.messages.get(timeout=0.25)
            except queue.Empty:
                continue
            event = message.get("event")
            if event == "property-change":
                seconds = clock.update(message["name"], message.get("data"), timestamp)
                if seconds:
                    outbox.add(occurrence_id, seconds)
            elif event == "end-file":
                natural_end = message.get("reason") == "eof"
                break
            elif event in ("shutdown", "ipc-closed"):
                break
            if connection_failed.is_set():
                print("Connection interrupted; measured events are retained locally.")
                connection_failed.clear()
        stop_flush.set()
        flusher.join(timeout=0.5)
        outbox.add(occurrence_id, 0, completed=natural_end)
        outbox.flush(client)
        if report_activity:
            client.call("/api/reporting/flush", {})
        result = {
            "occurrence_id": occurrence_id,
            "seconds": round(clock.total, 3),
            "coverage_seconds": round(clock.coverage(), 3),
            "natural_end": natural_end,
            "source_codec": clock.properties.get("audio-codec-name"),
        }
        client.call("/api/checks/playback", result)
        return result
    finally:
        if "stop_flush" in locals():
            stop_flush.set()
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
        if ipc:
            ipc.close()
        if os.name != "nt":
            Path(endpoint).unlink(missing_ok=True)
        lockfile.close()
