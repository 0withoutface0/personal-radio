"""Standalone provider sessions kept in the platform's encrypted vault."""

import functools
import json
import re
import time
from contextlib import suppress
from urllib.parse import parse_qs, quote, urlsplit

import requests
from ytmusicapi import YTMusic
from ytmusicapi.exceptions import YTMusicError, YTMusicServerError
from ytmusicapi.navigation import nav

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


ACCOUNT_MENU = ["actions", 0, "openPopupAction", "popup", "multiPageMenuRenderer"]
ACTIVE_ACCOUNT = ["header", "activeAccountHeaderRenderer"]


class BrowserYouTube(YTMusic):
    renew = None
    renewable_reads = frozenset({
        "account/account_menu", "browse", "search", "next", "player",
        "navigation/resolve_url", "music/get_search_suggestions",
    })

    def _send_request(self, endpoint, body, additionalParams=""):
        if self.renew is None or endpoint not in self.renewable_reads:
            return super()._send_request(endpoint, body, additionalParams)
        try:
            result = super()._send_request(endpoint, dict(body), additionalParams)
        except YTMusicServerError as exc:
            if not re.match(r"Server returned HTTP (401|403)\b", str(exc)):
                raise
        else:
            signed_out = nav(
                result, ["responseContext", "mainAppWebResponseContext", "loggedOut"], True,
            ) is True
            missing_account = endpoint == "account/account_menu" and nav(
                result, ACCOUNT_MENU + ACTIVE_ACCOUNT, True,
            ) is None
            if not signed_out and not missing_account:
                return result
        replacement = self.renew(self)
        # The same read may be attempted once with independently verified
        # credentials. Mutations never take this route.
        return YTMusic._send_request(replacement, endpoint, body, additionalParams)


def youtube_client(auth):
    session = requests.Session()
    session.request = functools.partial(session.request, timeout=20)
    return BrowserYouTube(auth, requests_session=session)


def _channel_id(value):
    return value if isinstance(value, str) and re.fullmatch(r"UC[A-Za-z0-9_-]{22}", value) else None


def _resolve_music_handle(client, handle):
    if not isinstance(handle, str) or not handle.startswith("@") or len(handle) < 2:
        return None
    try:
        result = client._send_request(
            "navigation/resolve_url", {"url": "https://music.youtube.com/" + quote(handle, safe="@")}
        )
        return _channel_id(nav(result, ["endpoint", "browseEndpoint", "browseId"], True))
    except (requests.RequestException, YTMusicError, ValueError):
        return None


def youtube_account(client):
    # get_account_info only returns display fields. Read its authenticated menu
    # once so that the active account's own channel link can supply the ID.
    response = client._send_request("account/account_menu", {})
    menu = nav(response, ACCOUNT_MENU)
    header = nav(menu, ACTIVE_ACCOUNT)
    name = nav(header, ["accountName", "runs", 0, "text"])
    if not isinstance(name, str) or not name:
        raise ValueError("Missing active YouTube account")
    handle = nav(header, ["channelHandle", "runs", 0, "text"], True)
    label = handle if isinstance(handle, str) and handle else name

    channels = set()
    for section in nav(menu, ["sections"], True) or []:
        for item in nav(section, ["multiPageMenuSectionRenderer", "items"], True) or []:
            link = nav(item, ["compactLinkRenderer"], True)
            if nav(link, ["icon", "iconType"], True) != "ACCOUNT_BOX":
                continue
            channel = _channel_id(
                nav(link, ["navigationEndpoint", "browseEndpoint", "browseId"], True)
            )
            if channel:
                channels.add(channel)
    if len(channels) > 1:
        return label, None
    return label, next(iter(channels), None) or _resolve_music_handle(client, handle)


def renewal_config(origin, token):
    try:
        url = urlsplit(origin.strip())
        valid = (
            url.scheme == "https" and url.hostname
            and re.fullmatch(r"(?:[a-z0-9-]+\.)+ts\.net", url.hostname)
            and not url.username and not url.password
            and url.netloc.lower() in {url.hostname, f"{url.hostname}:{url.port}"}
            and url.path in ("", "/") and not url.query and not url.fragment
        )
    except ValueError:
        valid = False
    if not valid:
        raise ProviderUnavailable("Use your renewal server's private Tailscale HTTPS address.")
    token = token.strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{40,128}", token):
        raise ProviderUnavailable("Enter the YouTube renewal token from your server.")
    return {"origin": f"https://{url.netloc.lower()}", "token": token}


def fetch_youtube_session(config):
    with requests.Session() as session:
        session.trust_env = False
        try:
            with session.post(
                config["origin"] + "/v1/session",
                headers={"Authorization": "Bearer " + config["token"]},
                timeout=(5, 40),
                allow_redirects=False,
                stream=True,
            ) as response:
                if response.status_code in (401, 403):
                    raise ProviderUnavailable("The server rejected the YouTube renewal token.")
                if response.status_code == 503:
                    raise ProviderUnavailable("Open the OMV browser and sign in to YouTube Music.")
                if response.status_code != 200:
                    raise ProviderUnavailable("The YouTube renewal server is unavailable.")
                data = bytearray()
                for chunk in response.iter_content(8192):
                    data.extend(chunk)
                    if len(data) > 100_000:
                        raise ValueError("Renewal response too large")
                result = json.loads(data)
                if not _channel_id(result["channel"]) or not isinstance(result["auth"], dict):
                    raise ValueError("Invalid renewal session")
                return result
        except requests.RequestException:
            raise ProviderUnavailable(
                "Could not reach the YouTube renewal server. Check Tailscale and try again."
            ) from None
        except (KeyError, TypeError, ValueError):
            raise ProviderUnavailable("The YouTube renewal server returned an invalid session.") from None


class LocalProviders(Providers):
    def __init__(self, settings, vault):
        super().__init__(settings)
        self.vault = vault
        self.records = vault.read("accounts")
        if self.records is None:
            self.records = {name: vault.read(name) for name in ACCOUNT_NAMES}
        self.pkce_until = 0
        self._youtube_check_at = 0
        self._youtube_retry_at = 0
        self._youtube_renewal_error = None

    def status(self):
        with self.lock:
            return {
                name: {
                    "credential_file": record is not None,
                    "label": record.get("label") if record else None,
                    "reporting": bool(record and record.get("identity")),
                    **({"renewal_server": record["renewal"]["origin"]}
                       if name == "youtube" and record and record.get("renewal") else {}),
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
            if record.get("renewal"):
                if time.monotonic() >= self._youtube_check_at:
                    self._check_managed_youtube(record)
                return self.youtube
            if self.youtube is None:
                self.youtube = youtube_client(record["auth"])
            return self.youtube

    def _set_youtube(self, record, client):
        self._save("youtube", record)
        self.youtube = client
        self._youtube_check_at = time.monotonic() + 600
        self._youtube_retry_at = 0
        self._youtube_renewal_error = None
        if record.get("renewal") and isinstance(client, BrowserYouTube):
            client.renew = self._renew_after_read

    def _install_renewal(self, config, expected_channel):
        result = fetch_youtube_session(config)
        if expected_channel and result["channel"] != expected_channel:
            raise ProviderUnavailable(
                "The server is signed into a different YouTube Music channel."
            )
        record, client = self._verified_youtube(json.dumps(result["auth"]))
        if record["identity"] != result["channel"]:
            raise ProviderUnavailable("Could not verify the server's YouTube Music channel.")
        self._set_youtube(record | {"renewal": config}, client)
        return client

    def connect_youtube_server(self, origin, token):
        config = renewal_config(origin, token)
        with self.lock:
            self._install_renewal(config, self.identity("youtube"))

    def stop_youtube_renewal(self):
        with self.lock:
            saved = self.records["youtube"]
            if saved and saved.get("renewal"):
                record = {key: value for key, value in saved.items() if key != "renewal"}
                self._set_youtube(record, None)

    def _renew_managed(self, saved, *, force=False):
        if not force and time.monotonic() < self._youtube_retry_at:
            raise ProviderUnavailable(self._youtube_renewal_error)
        try:
            return self._install_renewal(saved["renewal"], saved["identity"])
        except ProviderUnavailable as error:
            self._youtube_retry_at = time.monotonic() + 60
            self._youtube_renewal_error = str(error)
            raise

    def _renew_after_read(self, client):
        with self.lock:
            saved = self.records["youtube"]
            if saved is None or not saved.get("renewal"):
                raise ProviderUnavailable("Reconnect YouTube Music in Accounts.")
            if self.youtube is not client and self.youtube is not None:
                return self.youtube
            self._youtube_check_at = 0
            return self._renew_managed(saved)

    def _check_managed_youtube(self, saved, *, force=False):
        if not force and time.monotonic() < self._youtube_retry_at:
            raise ProviderUnavailable(self._youtube_renewal_error)
        # Verify the currently saved cookies before contacting OMV. Use a
        # separate client so the account check cannot trigger a nested renewal.
        try:
            record, client = self._read_youtube(saved["auth"])
        except ProviderUnavailable:
            return self._renew_managed(saved, force=force)
        if record["identity"] != saved["identity"]:
            return self._renew_managed(saved, force=force)
        if record != {key: value for key, value in saved.items() if key != "renewal"}:
            self._set_youtube(record | {"renewal": saved["renewal"]}, client)
        else:
            self.youtube = self.youtube or client
            self._youtube_check_at = time.monotonic() + 600
            self._youtube_retry_at = 0
            self._youtube_renewal_error = None
            if isinstance(self.youtube, BrowserYouTube):
                self.youtube.renew = self._renew_after_read
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
        return LocalProviders._read_youtube(auth)

    @staticmethod
    def _read_youtube(auth, client=None):
        try:
            client = client if client is not None else youtube_client(auth)
            label, identity = youtube_account(client)
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
        return {"auth": auth, "label": label, "identity": identity}, client

    def check_youtube(self):
        with self.lock:
            saved = self.records["youtube"]
            if saved and saved.get("renewal"):
                self._check_managed_youtube(saved, force=True)
            elif saved is not None:
                record, client = self._read_youtube(saved["auth"], self.youtube)
                if record != saved:
                    self._save("youtube", record)
                self.youtube = client
            return self.status()["youtube"]

    def connect_youtube(self, headers):
        with self.lock:
            record, client = self._verified_youtube(headers)
            self._set_youtube(record, client)

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
