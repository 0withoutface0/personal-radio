import os
import secrets
from dataclasses import dataclass
from pathlib import Path


def private_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as file:
        file.write(text)
    if os.name != "nt":
        path.chmod(0o600)


@dataclass
class Settings:
    data: Path
    local_setup: bool = True

    @classmethod
    def from_env(cls):
        return cls(
            Path(os.environ.get("RADIO_DATA_DIR", "data")).resolve(),
            os.environ.get("RADIO_LOCAL_SETUP", "1") == "1",
        )

    def __post_init__(self):
        self.data.mkdir(parents=True, exist_ok=True)
        if os.name != "nt":
            self.data.chmod(0o700)

    @property
    def youtube_file(self):
        return self.data / "youtube-browser.json"

    @property
    def tidal_file(self):
        return self.data / "tidal-pkce.json"

    @property
    def token_file(self):
        return self.data / "device-token.txt"

    @property
    def allowed_hosts(self):
        return [
            "localhost",
            "127.0.0.1",
            "[::1]",
            *[
                host.strip()
                for host in os.environ.get("RADIO_ALLOWED_HOSTS", "").split(",")
                if host.strip()
            ],
        ]

    def device_token(self):
        if not self.token_file.exists():
            private_write(self.token_file, secrets.token_urlsafe(32))
        return self.token_file.read_text(encoding="utf-8").strip()
