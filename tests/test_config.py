import json

import pytest
from fastapi.testclient import TestClient

from radio_prototype.api import create_app
from radio_prototype.config import Settings


@pytest.fixture
def data(tmp_path, monkeypatch):
    monkeypatch.setenv("RADIO_DATA_DIR", str(tmp_path))
    monkeypatch.delenv("RADIO_LOCAL_SETUP", raising=False)
    monkeypatch.delenv("RADIO_ALLOWED_HOSTS", raising=False)
    return tmp_path


def test_private_proxy_settings_survive_new_instances_without_broadening_access(data):
    (data / "server-settings.json").write_text(
        json.dumps(
            {
                "local_setup": False,
                "allowed_hosts": ["radio.example.ts.net", "100.64.1.2"],
            }
        ),
        encoding="utf-8",
    )
    for _ in range(2):
        settings = Settings.from_env()
        with TestClient(create_app(settings), base_url="https://radio.example.ts.net") as client:
            assert client.get("/").status_code == 404
            assert client.get("/api/accounts").status_code == 401
            assert (
                client.get(
                    "/api/accounts", headers={"Authorization": "Bearer " + settings.device_token()}
                ).status_code
                == 200
            )
            assert (
                client.get("/api/accounts", headers={"Host": "unrelated.example"}).status_code
                == 400
            )
            assert (
                client.post(
                    "/setup/tidal/start",
                    headers={"Authorization": "Bearer " + settings.device_token()},
                ).status_code
                == 404
            )


def test_environment_override_and_existing_loopback_defaults(data, monkeypatch):
    assert Settings.from_env().local_setup
    (data / "server-settings.json").write_text(
        '{"local_setup": false, "allowed_hosts": ["radio.example.ts.net"]}', encoding="utf-8"
    )
    monkeypatch.setenv("RADIO_LOCAL_SETUP", "1")
    monkeypatch.setenv("RADIO_ALLOWED_HOSTS", "other.example.ts.net")
    settings = Settings.from_env()
    assert settings.local_setup
    assert {"localhost", "127.0.0.1", "radio.example.ts.net", "other.example.ts.net"} <= set(
        settings.allowed_hosts
    )


@pytest.mark.parametrize(
    "config",
    [
        [],
        {"allowed_hosts": "*"},
        {"allowed_hosts": ["*"]},
        {"allowed_hosts": ["https://radio.ts.net"]},
        {"allowed_hosts": ["bad host"]},
        {"local_setup": "false"},
        {"unknown": True},
    ],
)
def test_malformed_private_settings_fail_instead_of_exposing_setup(data, config):
    (data / "server-settings.json").write_text(json.dumps(config), encoding="utf-8")
    with pytest.raises(ValueError):
        Settings.from_env()
