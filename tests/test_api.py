from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from radio_prototype.api import create_app
from radio_prototype.config import Settings


@pytest.fixture
def api(tmp_path):
    settings = Settings(tmp_path)
    provider = SimpleNamespace(
        track=lambda track_id: {
            "id": track_id,
            "title": "Song",
            "artists": ["Artist"],
            "duration": 180,
        },
        recommendations=lambda *args: {
            "playlist_id": "RDpersonal",
            "tracks": [{"video_id": "song"}],
        },
        stations=lambda: [{"id": "RDpersonal", "title": "My Mix"}],
    )
    app = create_app(settings, provider)
    with TestClient(app, base_url="http://localhost") as client:
        yield client, app, {"Authorization": "Bearer " + settings.device_token()}


def test_api_requires_token_and_openapi_is_protected(api):
    client, _, auth = api
    assert client.get("/api/accounts").status_code == 401
    assert client.get("/api/openapi.json").status_code == 401
    response = client.get("/api/openapi.json", headers=auth)
    assert response.status_code == 200
    assert "/api/events" in response.json()["paths"]


def test_setup_cookies_require_same_origin_for_mutations(api):
    client, _, _ = api
    assert client.get("/").status_code == 200
    assert client.get("/api/accounts").status_code == 200
    assert client.post("/api/occurrences", json={"tidal_id": 1}).status_code == 403
    assert (
        client.post(
            "/api/occurrences", headers={"Origin": "https://evil.example"}, json={"tidal_id": 1}
        ).status_code
        == 403
    )
    assert (
        client.post(
            "/api/occurrences", headers={"Origin": "http://localhost"}, json={"tidal_id": 1}
        ).status_code
        == 200
    )


def test_setup_refuses_forwarded_requests_and_host_rebinding(api):
    client, _, _ = api
    assert client.get("/", headers={"X-Forwarded-For": "100.64.1.2"}).status_code == 403
    assert client.get("/", headers={"Host": "evil.example"}).status_code == 400


def test_events_survive_duplicates_and_conflicts_are_rejected(api):
    client, app, auth = api
    occurrence = client.post(
        "/api/occurrences", headers=auth, json={"tidal_id": 1, "video_id": "youtube"}
    ).json()
    event = {"id": str(uuid4()), "occurrence_id": occurrence["id"], "seconds": 3}
    assert client.post("/api/events", headers=auth, json=event).json()["inserted"]
    assert not client.post("/api/events", headers=auth, json=event).json()["inserted"]
    assert client.post("/api/events", headers=auth, json=event | {"seconds": 2}).status_code == 422
    assert app.state.store.get_occurrence(occurrence["id"])["listened"] == 3


def test_personal_mix_must_be_from_signed_in_home(api):
    client, app, auth = api
    assert (
        client.post("/api/radio", headers=auth, json={"playlist_id": "unrelated"}).status_code
        == 422
    )
    assert (
        client.post("/api/radio", headers=auth, json={"playlist_id": "RDpersonal"}).status_code
        == 200
    )
    assert app.state.store.report()["evidence"][-1]["kind"] == "personal_mix"


def test_no_playback_gate_without_decode_and_complete_coverage(api):
    client, _, auth = api
    occurrence = client.post("/api/occurrences", headers=auth, json={"tidal_id": 1}).json()
    result = client.post(
        "/api/checks/playback",
        headers=auth,
        json={
            "occurrence_id": occurrence["id"],
            "seconds": 180,
            "coverage_seconds": 180,
            "natural_end": True,
            "source_codec": "flac",
        },
    )
    assert result.status_code == 200
    assert not result.json()["verified"]


def test_setup_can_be_disabled(tmp_path):
    with TestClient(
        create_app(Settings(tmp_path, local_setup=False)), base_url="http://localhost"
    ) as client:
        assert client.get("/").status_code == 404


def test_client_occurrence_ids_survive_retries_and_restart(api):
    client, app, auth = api
    body = {"id": str(uuid4()), "tidal_id": 1, "video_id": "song"}
    assert client.post("/api/occurrences", headers=auth, json=body).json()["id"] == body["id"]
    assert client.post("/api/occurrences", headers=auth, json=body).json()["id"] == body["id"]
    assert app.state.store.report()["totals"]["occurrences"] == 1
    assert (
        client.post("/api/occurrences", headers=auth, json=body | {"tidal_id": 2}).status_code
        == 422
    )


def test_device_takeover_and_lease_expiry(api, monkeypatch):
    client, app, auth = api
    first, second = str(uuid4()), str(uuid4())
    assert (
        client.post("/api/device/lease", headers=auth, json={"device_id": first}).status_code == 200
    )
    assert (
        client.post("/api/device/lease", headers=auth, json={"device_id": second}).status_code
        == 409
    )
    assert (
        client.post(
            "/api/streams", headers=auth | {"X-Device-ID": second}, json={"tidal_id": 1}
        ).status_code
        == 409
    )
    assert (
        client.post(
            "/api/device/lease", headers=auth, json={"device_id": second, "force": True}
        ).status_code
        == 200
    )
    assert not app.state.store.owns_lease(first)
    assert (
        client.post(
            "/api/device/lease", headers=auth, json={"device_id": first, "release": True}
        ).status_code
        == 200
    )
    assert not app.state.store.owns_lease(first)
    monkeypatch.setattr("radio_prototype.store.time.time", lambda: 10**12)
    assert (
        client.post("/api/device/lease", headers=auth, json={"device_id": first}).status_code == 200
    )


def test_explicit_rating_changes_have_distinct_retry_safe_event_ids(api):
    client, app, auth = api
    occurrence = client.post(
        "/api/occurrences", headers=auth, json={"tidal_id": 1, "video_id": "song"}
    ).json()
    rating = {"id": str(uuid4()), "occurrence_id": occurrence["id"], "value": "LIKE"}
    for _ in range(2):
        assert client.post("/api/ratings", headers=auth, json=rating).status_code == 200
    assert (
        client.post("/api/ratings", headers=auth, json=rating | {"value": "DISLIKE"}).status_code
        == 422
    )
    assert (
        client.post(
            "/api/ratings", headers=auth, json=rating | {"id": str(uuid4()), "value": "DISLIKE"}
        ).status_code
        == 200
    )
    assert len(app.state.store.submissions()) == 2
