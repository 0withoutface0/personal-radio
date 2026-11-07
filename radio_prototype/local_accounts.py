"""Standalone provider sessions kept in the platform's encrypted vault."""

import functools
import json
import re
import time
from urllib.parse import parse_qs, urlsplit

import requests
from ytmusicapi import YTMusic

from .providers import Providers, ProviderUnavailable

YOUTUBE_HEADERS = ("authorization", "cookie", "x-goog-authuser", "x-goog-pageid")


def browser_auth(text):
    if text.lstrip().startswith("{"):
        data = json.loads(text)
    else:
        import ytmusicapi

        data = json.loads(ytmusicapi.setup(headers_raw=text))
    if not isinstance(data, dict):
        raise ValueError("Expected YouTube browser credentials")
    data = {key.lower(): value for key, value in data.items()}
    selected = {key: data[key] for key in YOUTUBE_HEADERS if key in data}
    if any(
        not isinstance(value, str) or "\r" in value or "\n" in value for value in selected.values()
    ):
        raise ValueError("Invalid browser credentials")
    if not selected.get("authorization") or not selected.get("cookie"):
        raise ValueError("YouTube browser authorization and cookies are required")
    selected.setdefault("x-goog-authuser", "0")
    if not re.fullmatch(r"[0-9]{1,4}", selected["x-goog-authuser"]):
        raise ValueError("Invalid YouTube account selector")
    selected["x-origin"] = "https://music.youtube.com"
    return selected


def youtube_client(auth):
    session = requests.Session()
    session.request = functools.partial(session.request, timeout=20)
    return YTMusic(auth, requests_session=session)


def youtube_identity(client, handle):
    if not isinstance(handle, str) or not handle.startswith("@") or "/" in handle:
        return None
    try:
        result = client._send_request(
            "navigation/resolve_url",
            {
                "url": "https://www.youtube.com/" + handle,
            },
        )
        channel = result["endpoint"]["browseEndpoint"]["browseId"]
        if re.fullmatch(r"UC[A-Za-z0-9_-]{22}", channel):
            return channel
    except Exception:
        pass
    # Unidentified accounts can play, but cannot receive unattended writes.
    return None


class LocalProviders(Providers):
    def __init__(self, settings, vault):
        super().__init__(settings)
        self.vault = vault
        self.records = {name: vault.read(name) for name in ("youtube", "tidal")}
        self.pkce_until = 0

    def status(self):
        with self.lock:
            return {
                name: {
                    "credential_file": record is not None,
                    "label": record.get("label") if record else None,
                    "reporting": bool(record and record.get("identity")),
                }
                for name, record in self.records.items()
            }

    def identity(self, provider):
        with self.lock:
            record = self.records[provider]
            return record.get("identity") if record else None

    def _save(self, provider, record):
        self.vault.write(provider, record)
        self.records[provider] = record

    def yt(self):
        with self.lock:
            record = self.records["youtube"]
            if record is None:
                raise ProviderUnavailable("Connect YouTube Music in Accounts.")
            if self.youtube is None:
                self.youtube = youtube_client(record["auth"])
            return self.youtube

    def connect_youtube(self, headers):
        with self.lock:
            try:
                auth = browser_auth(headers)
                client = youtube_client(auth)
                info = client.get_account_info()
            except Exception:
                raise ProviderUnavailable(
                    "YouTube could not verify this session. Sign in again and retry."
                ) from None
            handle = info.get("channelHandle")
            label = handle or info.get("accountName") or "YouTube Music"
            self._save(
                "youtube",
                {
                    "auth": auth,
                    "label": label,
                    "identity": youtube_identity(client, handle),
                },
            )
            self.youtube = client

    def youtube_transfer(self):
        with self.lock:
            record = self.records["youtube"]
            if record is None:
                raise ProviderUnavailable("Connect YouTube Music on Windows first.")
            return {"label": record["label"], "auth": record["auth"]}

    def td(self):
        with self.lock:
            record = self.records["tidal"]
            if record is None:
                raise ProviderUnavailable("Connect Tidal in Accounts.")
            if self.tidal is None:
                session = self.new_tidal()
                if not session.load_oauth_session(**record["auth"]) or not session.check_login():
                    raise ProviderUnavailable("Reconnect Tidal in Accounts.")
                self._save_tidal(session)
                self.tidal = session
            return self.tidal

    def _save_tidal(self, session):
        identity = str(session.user.id)
        self._save(
            "tidal",
            {
                "label": "Tidal account " + identity,
                "identity": identity,
                "auth": {
                    key: getattr(session, key)
                    for key in (
                        "token_type",
                        "access_token",
                        "refresh_token",
                        "is_pkce",
                    )
                },
            },
        )

    def start_pkce(self):
        with self.lock:
            url = super().start_pkce()
            self.pkce_until = time.monotonic() + 600
            return url

    def cancel_pkce(self):
        with self.lock:
            self.pending_pkce = None

    def finish_pkce(self, redirect):
        with self.lock:
            session = self.pending_pkce
            if session is None or time.monotonic() >= self.pkce_until:
                self.cancel_pkce()
                raise ProviderUnavailable("Start a new Tidal sign-in.")
            target = urlsplit(redirect.strip())
            expected = urlsplit(session.config.pkce_uri_redirect)
            if (target.scheme, target.netloc, target.path) != (
                expected.scheme,
                expected.netloc,
                expected.path,
            ) or not parse_qs(target.query).get("code"):
                raise ProviderUnavailable("Paste the final redirect from Tidal sign-in.")
            self.cancel_pkce()
            try:
                session.process_auth_token(
                    session.pkce_get_auth_token(redirect), is_pkce_token=True
                )
                if not session.check_login():
                    raise ValueError("Unverified Tidal account")
                self._save_tidal(session)
            except Exception:
                raise ProviderUnavailable("Tidal sign-in failed. Start a new attempt.") from None
            self.tidal = session

    def disconnect(self, provider):
        with self.lock:
            self.vault.delete(provider)
            self.records[provider] = None
            if provider == "youtube":
                self.youtube = None
            else:
                self.cancel_pkce()
                self.tidal = None

    def save_tidal(self, session):
        self._save_tidal(session)
