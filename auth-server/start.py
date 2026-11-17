"""Run an isolated, persistent browser with SSH-only interactive access."""
import os
import secrets
import subprocess
import time
from pathlib import Path

from radio_prototype.config import private_write


def main():
    os.umask(0o077)
    state = Path("/state")
    state.chmod(0o700)
    token = state / "device-token.txt"
    if not token.exists():
        private_write(token, secrets.token_urlsafe(32))
    password = state / "vnc.password"
    if not password.exists():
        private_write(password, secrets.token_hex(4))
    auth_file = state / "vnc.auth"
    subprocess.run(
        ["x11vnc", "-storepasswd", password.read_text(), str(auth_file)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    children = []

    def start(*command):
        children.append(subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))

    try:
        start("Xvfb", ":99", "-screen", "0", "1280x900x24", "-nolisten", "tcp")
        time.sleep(1)
        start("x11vnc", "-display", ":99", "-listen", "127.0.0.1", "-rfbauth", str(auth_file),
              "-forever", "-shared")
        start("websockify", "--web", "/usr/share/novnc", "0.0.0.0:8771", "127.0.0.1:5900")
        # Container isolation replaces Chromium's nested sandbox here. The
        # non-root browser only sees its dedicated volume and has no host socket.
        start("chromium", "--no-sandbox", "--disable-dev-shm-usage",
              "--no-first-run", "--no-default-browser-check", "--disable-sync",
              "--password-store=basic", "--user-data-dir=/state/chromium",
              "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=9222",
              "https://music.youtube.com/")
        children.append(subprocess.Popen([
            "python", "-m", "uvicorn", "app:create_app", "--factory",
            "--host", "0.0.0.0", "--port", "8770", "--no-proxy-headers", "--no-access-log",
        ]))
        while all(child.poll() is None for child in children):
            time.sleep(1)
        raise SystemExit("A YouTube auth service process exited.")
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()


if __name__ == "__main__":
    main()
