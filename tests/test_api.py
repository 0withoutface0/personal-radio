from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from radio_prototype.api import create_app
from radio_prototype.config import Settings
from radio_prototype.providers import Providers


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


def test_match_accepts_counterpart_without_creating_listening_activity(tmp_path):
    settings = Settings(tmp_path)
    observed = []

    def match(source):
        observed.append(source)
        return {"status": "matched", "method": "youtube_counterpart", "track": {"id": 123}}

    app = create_app(settings, SimpleNamespace(match=match))
    auth = {"Authorization": "Bearer " + settings.device_token()}
    source = {
        "video_id": "original-video",
        "title": "Song (Official Video)",
        "artists": ["Artist"],
        "duration": 302,
        "video_type": "MUSIC_VIDEO_TYPE_OMV",
        "counterpart": {
            "video_id": "audio",
            "title": "Song",
            "artists": ["Artist"],
            "album": "Single",
            "duration": 275,
            "video_type": "MUSIC_VIDEO_TYPE_ATV",
        },
    }
    with TestClient(app, base_url="http://localhost") as client:
        response = client.post("/api/match", headers=auth, json=source)
    assert response.status_code == 200
    assert observed[0]["video_id"] == "original-video"
    assert observed[0]["counterpart"]["video_id"] == "audio"
    assert observed[0]["counterpart"]["duration"] == 275
    assert app.state.store.report()["totals"]["occurrences"] == 0
    assert app.state.store.submissions() == []


@pytest.mark.parametrize("include_artists", [False, True])
def test_match_song_with_artistless_video_counterpart(tmp_path, include_artists):
    settings = Settings(tmp_path)
    provider = Providers(settings)
    track = {
        "id": 123,
        "title": "Song (feat. Guest)",
        "artists": ["Artist", "Guest"],
        "album": "Single",
        "duration": 203,
        "explicit": True,
        "isrc": "FAKE123",
    }
    provider.candidates = lambda source: [track]
    source = {
        "video_id": "official-audio",
        "title": "Song (feat. Guest)",
        "artists": ["Artist"],
        "album": "Single",
        "duration": 203,
        "explicit": True,
        "video_type": "MUSIC_VIDEO_TYPE_ATV",
        "counterpart": {
            "video_id": "music-video",
            "title": "Artist - Song ft Guest",
            "duration": 203,
            "video_type": "MUSIC_VIDEO_TYPE_OMV",
        },
    }
    if include_artists:
        source["counterpart"]["artists"] = []
    app = create_app(settings, provider)
    auth = {"Authorization": "Bearer " + settings.device_token()}
    with TestClient(app, base_url="http://localhost") as client:
        response = client.post("/api/match", headers=auth, json=source)
        assert response.status_code == 200
        assert response.json()["status"] == "matched"
        assert response.json()["track"]["id"] == 123
        # Optional metadata cannot relax the primary recording's constraints.
        wrong_version = client.post("/api/match", headers=auth, json=source | {"explicit": False})
        assert wrong_version.status_code == 200
        assert wrong_version.json()["status"] == "skipped"
        assert "explicit/clean" in wrong_version.json()["reason"]
    assert app.state.store.report()["totals"]["occurrences"] == 0
    assert app.state.store.submissions() == []


def test_match_still_requires_primary_artist_metadata(api):
    client, _, auth = api
    response = client.post(
        "/api/match", headers=auth, json={"video_id": "audio", "title": "Song", "artists": []}
    )
    assert response.status_code == 422
    assert response.json()["detail"][0]["loc"] == ["body", "artists"]


def test_counterpart_artist_limit_stays_bounded(api):
    client, _, auth = api
    response = client.post(
        "/api/match",
        headers=auth,
        json={
            "video_id": "audio",
            "title": "Song",
            "artists": ["Artist"],
            "counterpart": {"video_id": "video", "title": "Song", "artists": ["A"] * 21},
        },
    )
    assert response.status_code == 422
    assert response.json()["detail"][0]["loc"] == ["body", "counterpart", "artists"]


def test_manual_correction_takes_priority_over_audio_resolution(api):
    client, app, auth = api
    app.state.store.correction("video", 123)
    response = client.post(
        "/api/match",
        headers=auth,
        json={"video_id": "video", "title": "Song", "artists": ["Artist"]},
    )
    assert response.status_code == 200
    assert response.json()["method"] == "manual"
    assert response.json()["track"]["id"] == 123


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
    rows = app.state.store.submissions()
    assert len(rows) == 4
    assert {row["provider"] for row in rows} == {"youtube", "tidal"}


def test_listening_buckets_deduplicate_and_keep_offline_play_dates(api, monkeypatch):
    client, _, auth = api
    monkeypatch.setattr("radio_prototype.store.now", lambda: "2026-10-26T12:00:00+00:00")

    def occurrence(track):
        return client.post(
            "/api/occurrences", headers=auth, json={"tidal_id": track, "video_id": str(track)}
        ).json()["id"]

    def event(occurrence_id, seconds, **extra):
        body = {"id": str(uuid4()), "occurrence_id": occurrence_id, "seconds": seconds, **extra}
        assert client.post("/api/events", headers=auth, json=body).json()["inserted"]
        assert not client.post("/api/events", headers=auth, json=body).json()["inserted"]
        return body

    first, repeat, other, never_heard = [occurrence(track) for track in (1, 1, 2, 3)]
    # Offset changes overnight. The two 02:00 hours are separate chart buckets.
    offline = event(first, 3, played_at="2026-10-25T02:30:00+02:00")
    event(first, 2, played_at="2026-10-25T02:00:00+01:00")
    event(repeat, 4, played_at="2026-10-25T02:30:00+01:00")
    event(other, 5)  # Old clients still use the server receipt timestamp.
    event(never_heard, 0, completed=True)
    assert (
        client.post(
            "/api/events", headers=auth, json=offline | {"played_at": "2026-10-25T04:00:00Z"}
        ).status_code
        == 422
    )
    for occurrence_id, choice in [(first, "LIKE"), (other, "LIKE"), (other, "INDIFFERENT")]:
        assert (
            client.post(
                "/api/ratings",
                headers=auth,
                json={"occurrence_id": occurrence_id, "id": str(uuid4()), "value": choice},
            ).status_code
            == 200
        )

    boundaries = [
        "2026-10-25T02:00:00+02:00",
        "2026-10-25T02:00:00+01:00",
        "2026-10-25T03:00:00+01:00",
    ]
    request = {"boundaries": boundaries}
    assert client.post("/api/listening", json=request).status_code == 401
    day = client.post("/api/listening", headers=auth, json=request).json()
    assert day["first_played_at"] == "2026-10-25T00:30:00+00:00"
    assert day["totals"] == {"listened_seconds": 9, "plays": 2, "songs": 1, "artists": 1}
    assert [row["listened_seconds"] for row in day["buckets"]] == [3, 6]
    assert day["most_played"][0]["plays"] == 2
    assert [row["tidal_id"] for row in day["liked_songs"]] == [1]

    all_time = client.post(
        "/api/listening",
        headers=auth,
        json={"boundaries": ["2026-10-26T00:00:00Z", "2026-10-27T00:00:00Z"], "all_time": True},
    ).json()
    assert all_time["totals"] == {"listened_seconds": 14, "plays": 3, "songs": 2, "artists": 1}
    assert all_time["buckets"][0]["start"] is None
    assert [row["listened_seconds"] for row in all_time["buckets"]] == [9, 5]
    assert [row["tidal_id"] for row in all_time["liked_songs"]] == [1]
    assert all_time["top_artists"][0]["listened_seconds"] == 14
    assert (
        client.post(
            "/api/listening", headers=auth, json={"boundaries": boundaries[::-1]}
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/api/listening",
            headers=auth,
            json={"boundaries": ["2026-10-25T00:00:00", boundaries[-1]]},
        ).status_code
        == 422
    )
