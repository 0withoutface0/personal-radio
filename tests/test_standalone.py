import json
import os

import pytest
import requests
from fastapi.testclient import TestClient

from radio_prototype.api import create_app
from radio_prototype.config import Settings
from radio_prototype.embedded import Engine
from radio_prototype.local_accounts import LocalProviders
from radio_prototype.vault import windows_vault


class MemoryVault:
    def __init__(self):
        self.records = {}

    def read(self, key):
        return self.records.get(key)

    def write(self, key, value):
        self.records[key] = value

    def delete(self, key):
        self.records.pop(key)


class FakeYouTube:
    def get_account_info(self):
        return {"channelHandle": "@fixture"}

    def _send_request(self, endpoint, body):
        assert endpoint == "navigation/resolve_url"
        return {"endpoint": {"browseEndpoint": {"browseId": "UC" + "a" * 22}}}


def test_engine_requires_ephemeral_token_and_keeps_database(tmp_path):
    engine = Engine(tmp_path, vault=MemoryVault())
    info = engine.start()
    url = info["origin"] + "/api/accounts"
    try:
        assert info["origin"].startswith("http://127.0.0.1:")
        assert requests.get(url, timeout=2).status_code == 401
        response = requests.get(
            url, headers={"Authorization": "Bearer " + info["token"]}, timeout=2
        )
        assert response.json()["embedded"]
        assert not (tmp_path / "device-token.txt").exists()
        assert requests.get(info["origin"] + "/", timeout=2).status_code == 404
    finally:
        engine.stop()
    assert (tmp_path / "radio.sqlite3").exists()


def test_browser_connect_requires_one_time_approval_and_redacts_invalid_input(
    tmp_path, monkeypatch
):
    settings = Settings(tmp_path, local_setup=False)
    vault = MemoryVault()
    providers = LocalProviders(settings, vault)
    monkeypatch.setattr("radio_prototype.local_accounts.youtube_client", lambda _: FakeYouTube())
    app = create_app(settings, providers, runtime_token="device-test", embedded=True)
    auth = {"Authorization": "Bearer device-test"}
    body = {
        "text": json.dumps(
            {"authorization": "fixture", "cookie": "session=test", "ignored": "do not retain"}
        )
    }
    with TestClient(app, base_url="http://127.0.0.1") as client:
        result = client.post("/api/local/accounts/browser", headers=auth, json={})
        path, key = result.json()["path"].split("#")
        browser = {"Authorization": "Bearer " + key, "Origin": "moz-extension://fixture"}
        assert (
            client.post(
                path, headers=browser | {"Origin": "https://evil.invalid"}, json=body
            ).status_code
            == 403
        )
        assert client.post(path, headers=browser, json=body).json() == {"connected": True}
        assert client.post(path, headers=browser, json=body).status_code == 401
        assert "ignored" not in vault.records["youtube"]["auth"]
        assert providers.identity("youtube") == "UC" + "a" * 22
        response = client.post(
            "/api/local/accounts/youtube", headers=auth, json={"text": ["secret"]}
        )
        assert response.status_code == 422 and "secret" not in response.text
        assert client.delete("/api/local/accounts/youtube", headers=auth).status_code == 200
        assert vault.records == {}


@pytest.mark.skipif(os.name != "nt", reason="Windows DPAPI")
def test_windows_vault_encrypts_account_record(tmp_path):
    vault = windows_vault(tmp_path)
    vault.write("youtube", {"cookie": "private-fixture"})
    assert "private-fixture" not in (tmp_path / "youtube.sealed").read_text()
    assert vault.read("youtube") == {"cookie": "private-fixture"}
