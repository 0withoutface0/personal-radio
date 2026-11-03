"""Launch this PC's personal installation without changing PowerShell policy."""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
ORIGIN = "http://127.0.0.1:8765"


def available():
    try:
        token = (DATA / "device-token.txt").read_text().strip()
        return (
            requests.get(
                ORIGIN + "/api/accounts", headers={"Authorization": "Bearer " + token}, timeout=2
            ).status_code
            == 200
        )
    except (OSError, requests.RequestException):
        return False


def main():
    app = ROOT / "dist/windows/PersonalRadio/personal_radio.exe"
    if not app.is_file():
        app = ROOT / "player/build/windows/x64/runner/Release/personal_radio.exe"
    if not app.is_file():
        raise RuntimeError("Build or unpack the Windows release first; see player/README.md.")
    DATA.mkdir(exist_ok=True)
    if not available():
        with (
            (DATA / "server.log").open("w") as output,
            (DATA / "server-error.log").open("w") as errors,
        ):
            service = subprocess.Popen(
                [sys.executable, "-m", "radio_prototype", "serve"],
                cwd=ROOT,
                stdout=output,
                stderr=errors,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        (DATA / "server.pid").write_text(str(service.pid))
        for _ in range(40):
            time.sleep(0.5)
            if service.poll() is not None:
                raise RuntimeError("Server could not start. Check data/server-error.log.")
            if available():
                break
        else:
            raise RuntimeError("Server did not respond. Check data/server-error.log.")
    pairing = DATA / "windows-pairing.json"
    pairing.write_text(
        json.dumps({"origin": ORIGIN, "token": (DATA / "device-token.txt").read_text().strip()}),
        encoding="utf-8",
    )
    process = subprocess.Popen(
        [str(app)], cwd=app.parent, env={**os.environ, "RADIO_PAIRING_FILE": str(pairing)}
    )
    (DATA / "player.pid").write_text(str(process.pid))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else "Could not start Personal Radio.")
        raise SystemExit(1) from None
