import json

import pytest
from fastapi.testclient import TestClient
from ytmusicapi import YTMusic
from ytmusicapi.exceptions import YTMusicServerError

from radio_prototype.api import create_app
from radio_prototype.config import Settings
from radio_prototype.local_accounts import BrowserYouTube, LocalProviders, renewal_config
from radio_prototype.providers import ProviderUnavailable

from test_standalone import FakeYouTube, MemoryVault


ORIGIN = "https://omv.example.ts.net:8443"
TOKEN = "t" * 43


@pytest.mark.parametrize("origin", [
    "http://omv.example.ts.net", "https://omv.example.ts.net.evil.test",
    "https://other.test", "https://foo@omv.example.ts.net", "https://omv.example.ts.net/admin",
])
def test_renewal_requires_a_tailscale_https_origin(origin):
    with pytest.raises(ProviderUnavailable):
        renewal_config(origin, TOKEN)


def test_link_refresh_and_disable_preserve_the_channel_and_tidal(tmp_path, monkeypatch):
    auth = {"cookie": "fixture-cookie", "authorization": "fixture-auth"}
    vault = MemoryVault()
    youtube = {"auth": auth, "identity": FakeYouTube.channel, "label": "@fixture"}
    tidal = {"auth": {"access_token": "fixture"}, "identity": "1"}
    vault.write("accounts", {"youtube": youtube, "tidal": tidal})
    settings = Settings(tmp_path, local_setup=False)
    providers = LocalProviders(settings, vault)
    result = {"channel": "UC" + "b" * 22, "auth": auth}
    calls = []
    clients = []

    def fetch(config):
        calls.append(config)
        return result

    def make_client(auth):
        client = FakeYouTube()
        clients.append(client)
        return client

    monkeypatch.setattr("radio_prototype.local_accounts.fetch_youtube_session", fetch)
    monkeypatch.setattr("radio_prototype.local_accounts.youtube_client", make_client)
    app = create_app(settings, providers, runtime_token="device-test", embedded=True)
    path = "/api/local/accounts/youtube/renewal"
    body = {"origin": ORIGIN, "token": TOKEN}
    headers = {"Authorization": "Bearer device-test"}
    with TestClient(app, base_url="http://127.0.0.1") as client:
        assert client.put(path, json=body).status_code == 401
        mismatch = client.put(path, json=body, headers=headers)
        assert mismatch.status_code == 503
        assert "different" in mismatch.json()["detail"]
        assert vault.read("accounts")["youtube"] == youtube

        result["channel"] = FakeYouTube.channel
        connected = client.put(path, json=body, headers=headers)
        assert connected.status_code == 200
        assert connected.json()["renewal_server"] == ORIGIN
        assert TOKEN not in connected.text
        assert vault.read("accounts")["tidal"] == tidal

        # The engine preserves a valid session and checks it before asking OMV.
        reloaded = LocalProviders(settings, vault)
        assert reloaded.yt() is clients[-1]
        assert len(calls) == 2

        result["auth"] = auth | {"cookie": "fresh-cookie"}
        old_client = providers.youtube
        assert providers._renew_after_read(old_client) is not old_client
        assert len(calls) == 3
        assert providers._renew_after_read(old_client) is providers.youtube
        assert len(calls) == 3
        assert vault.read("accounts")["youtube"]["auth"]["cookie"] == "fresh-cookie"
        assert providers.identity("youtube") == FakeYouTube.channel

        stopped = client.delete(path, headers=headers)
        assert stopped.status_code == 200
        assert "renewal_server" not in stopped.json()
        assert stopped.json()["reporting"]
        assert TOKEN not in json.dumps(vault.records)
        assert vault.read("accounts")["tidal"] == tidal


def test_an_expired_read_retries_once_but_a_rating_never_replays(monkeypatch):
    old = object.__new__(BrowserYouTube)
    replacement = object.__new__(BrowserYouTube)
    calls = []

    def upstream(client, endpoint, body, params):
        calls.append((client, endpoint))
        if client is old:
            raise YTMusicServerError("Server returned HTTP 401: fixture")
        return {"ok": True}

    monkeypatch.setattr(YTMusic, "_send_request", upstream)
    old.renew = lambda client: replacement
    assert old._send_request("browse", {}) == {"ok": True}
    with pytest.raises(YTMusicServerError):
        old._send_request("like/like", {})
    assert calls == [(old, "browse"), (replacement, "browse"), (old, "like/like")]
