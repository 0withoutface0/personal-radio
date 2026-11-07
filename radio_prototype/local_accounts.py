"""Standalone provider sessions kept in the platform's encrypted vault."""

import functools
import json
import re
import time
from contextlib import suppress
from urllib.parse import parse_qs, urlsplit

import requests
from ytmusicapi import YTMusic
from ytmusicapi.exceptions import YTMusicError

from .providers import Providers, ProviderUnavailable

ACCOUNT_NAMES = ('youtube', 'tidal')
YOUTUBE_HEADERS = ("authorization", "cookie", "x-goog-authuser", "x-goog-pageid")


def browser_auth(text):
    text = text.strip()
    if not text:
        raise ValueError("Expected YouTube browser credentials")
    if text.startswith("{"):
        data = json.loads(text)
    else:
        import ytmusicapi

        # DevTools can copy CRLF on Windows. The upstream parser splits on LF only.
        raw = "\n".join(text.splitlines())
        # Supply the normal default while letting an explicit account selector override it.
        data = json.loads(ytmusicapi.setup(headers_raw="x-goog-authuser: 0\n" + raw))
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
        self.records = vault.read("accounts")
        if self.records is None:
            self.records = {name: vault.read(name) for name in ACCOUNT_NAMES}
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

    def _save_accounts(self, records):
        # Commit both records together. Older installations used one file per provider.
        self.vault.write("accounts", records)
        self.records = records
        for name in ACCOUNT_NAMES:
            with suppress(OSError):
                self.vault.delete(name)

    def _save(self, provider, record):
        self._save_accounts(self.records | {provider: record})

    def yt(self):
        with self.lock:
            record = self.records["youtube"]
            if record is None:
                raise ProviderUnavailable("Connect YouTube Music in Accounts.")
            if self.youtube is None:
                self.youtube = youtube_client(record["auth"])
            return self.youtube

    @staticmethod
    def _verified_youtube(headers):
        try:
            auth = browser_auth(headers)
        except (ValueError, YTMusicError):
            raise ProviderUnavailable(
                "Could not read the copied headers. Copy the full Request Headers from a "
                "signed-in YouTube Music browse request, including Cookie and Authorization."
            ) from None
        try:
            client = youtube_client(auth)
            info = client.get_account_info()
        except FileNotFoundError:
            raise ProviderUnavailable(
                "This installation is missing YouTube Music support files. "
                "Update Personal Radio and try again."
            ) from None
        except (requests.ConnectionError, requests.Timeout):
            raise ProviderUnavailable(
                "Could not reach YouTube Music. Check this device's connection and try again."
            ) from None
        except Exception:
            raise ProviderUnavailable(
                "YouTube Music could not verify the session. Sign in at music.youtube.com "
                "and copy fresh headers from a browse request."
            ) from None
        handle = info.get("channelHandle")
        label = handle or info.get("accountName") or "YouTube Music"
        return {
            "auth": auth,
            "label": label,
            "identity": youtube_identity(client, handle),
        }, client

    def connect_youtube(self, headers):
        with self.lock:
            record, client = self._verified_youtube(headers)
            self._save("youtube", record)
            self.youtube = client

    def setup_transfer(self):
        with self.lock:
            youtube = self.records["youtube"]
            tidal = self._tidal_record(self.tidal) if self.tidal else self.records["tidal"]
            if not youtube or not tidal or not tidal["auth"]["refresh_token"]:
                raise ProviderUnavailable("Connect both music accounts on Windows first.")
            return {"youtube": youtube["auth"], "tidal": tidal["auth"]}

    def import_setup(self, youtube_auth, tidal_auth):
        with self.lock:
            youtube, client = self._verified_youtube(json.dumps(youtube_auth))
            try:
                tidal = self.new_tidal()
                if not tidal.load_oauth_session(**tidal_auth) or not tidal.check_login():
                    raise ValueError("Unverified Tidal session")
                tidal_record = self._tidal_record(tidal)
            except Exception:
                raise ProviderUnavailable(
                    "Tidal could not verify the desktop session. Reconnect Tidal on Windows "
                    "and make a new setup code."
                ) from None
            self._save_accounts({"youtube": youtube, "tidal": tidal_record})
            self.youtube = client
            self.tidal = tidal
            self.cancel_pkce()

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

    @staticmethod
    def _tidal_record(session):
        identity = str(session.user.id)
        return {
            "label": "Tidal account " + identity,
            "identity": identity,
            "auth": {
                key: getattr(session, key)
                for key in ("token_type", "access_token", "refresh_token", "is_pkce")
            },
        }

    def _save_tidal(self, session):
        self._save("tidal", self._tidal_record(session))

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
            self._save(provider, None)
            if provider == "youtube":
                self.youtube = None
            else:
                self.cancel_pkce()
                self.tidal = None

    def save_tidal(self, session):
        self._save_tidal(session)
