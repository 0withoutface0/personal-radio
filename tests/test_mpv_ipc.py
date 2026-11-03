import os
import queue
import shutil
import subprocess
import time
from pathlib import Path
from uuid import uuid4

import pytest

from radio_prototype.playback import IPC


def test_installed_mpv_json_ipc(tmp_path):
    """Control protocol smoke test only; no audio is played or credited."""
    mpv = shutil.which("mpv") or Path(".tools/mpv/mpv.exe")
    if not Path(mpv).is_file():
        pytest.skip("mpv is not installed")
    endpoint = rf"\\.\pipe\radio-test-{uuid4()}" if os.name == "nt" else str(tmp_path / "mpv.sock")
    process = subprocess.Popen(
        [
            str(mpv),
            "--no-config",
            "--idle=yes",
            "--vo=null",
            "--ao=null",
            "--terminal=no",
            f"--input-ipc-server={endpoint}",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
    )
    ipc = None
    try:
        ipc = IPC(endpoint, process)
        ipc.command("get_property", "mpv-version")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                _, message = ipc.messages.get(timeout=0.2)
            except queue.Empty:
                continue
            if message.get("error") == "success" and isinstance(message.get("data"), str):
                assert message["data"].startswith("mpv ")
                return
        pytest.fail("mpv did not answer the JSON IPC command")
    finally:
        process.terminate()
        process.wait(timeout=5)
        if ipc:
            ipc.close()
