from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from radio_prototype.api import create_app
from radio_prototype.autoplay import WATCH_PANEL, Autoplay
from radio_prototype.config import Settings
from radio_prototype.providers import Providers, ProviderUnavailable
from radio_prototype.store import Store


def song(video_id):
    return {
        "playlistPanelVideoRenderer": {
            "videoId": video_id,
            "title": {"runs": [{"text": video_id}]},
            "lengthText": {"runs": [{"text": "3:20"}]},
            "menu": {"menuRenderer": {"items": []}},
            "longBylineText": {
                "runs": [
                    {
                        "text": "Artist",
                        "navigationEndpoint": {
                            "browseEndpoint": {"browseId": "UCartist"},
                        },
                    }
                ]
            },
        }
    }


def response(panel):
    result = panel
    for key in reversed(WATCH_PANEL):
        result = [result] if key == 0 else {key: result}
    return result


def panel(ids, token=None):
    result = {"contents": [song(video_id) for video_id in ids], "isInfinite": bool(token)}
    if token:
        result["continuations"] = [{"nextRadioContinuationData": {"continuation": token}}]
    return result


class FakeProviders:
    def __init__(self):
        self.calls = []
        self.autoplay_available = True
        self.fail_next_continuation = False
        self.include_seed_again = False
        self.repeat_token = False

    def watch_next(self, body, continuation=None):
        self.calls.append((deepcopy(body), continuation))
        if continuation:
            if self.fail_next_continuation:
                self.fail_next_continuation = False
                raise TimeoutError("Read timed out")
            seed = body["playlistId"].removeprefix("RDreturned-")
            return {
                "continuationContents": {
                    "playlistPanelContinuation": panel(
                        [f"{seed}-5", f"{seed}-6"],
                        continuation if self.repeat_token else None,
                    )
                }
            }
        if "playlistId" not in body:
            seed = body["videoId"]
            initial = panel([seed])
            if self.autoplay_available:
                initial["contents"].append(
                    {
                        "automixPreviewVideoRenderer": {
                            "content": {
                                "automixPlaylistVideoRenderer": {
                                    "navigationEndpoint": {
                                        "watchPlaylistEndpoint": {
                                            "playlistId": f"RDreturned-{seed}",
                                            "params": f"server-params-{seed}",
                                        }
                                    }
                                },
                            }
                        }
                    }
                )
            return response(initial)
        seed = body["playlistId"].removeprefix("RDreturned-")
        ids = [f"{seed}-{index}" for index in range(1, 5)]
        if self.include_seed_again:
            ids.insert(0, seed)
        return response(panel(ids, f"server-token-{seed}"))


@pytest.fixture
def autoplay(tmp_path):
    providers = FakeProviders()
    store = Store(tmp_path / "radio.sqlite3")
    return Autoplay(providers, store), providers, store


def ids(batch):
    return [track["video_id"] for track in batch["tracks"]]


def test_starts_with_bare_song_then_uses_returned_endpoint(autoplay):
    engine, providers, store = autoplay
    first = engine.start("seed", limit=3)
    initial, automix = [call[0] for call in providers.calls]
    assert initial["videoId"] == "seed"
    assert "playlistId" not in initial and "params" not in initial
    assert automix["playlistId"] == "RDreturned-seed"
    assert automix["params"] == "server-params-seed"
    assert "videoId" not in automix
    assert ids(first) == ["seed", "seed-1", "seed-2"]
    assert first["mode"] == "autoplay"
    assert "server-params" not in str(first) and "server-token" not in str(first)
    assert store.submissions() == []


def test_explicit_radio_keeps_mode_context_and_continuation(autoplay):
    engine, providers, store = autoplay
    first = engine.start_radio(video_id="seed", limit=3)
    assert first["mode"] == "radio"
    assert providers.calls[0][0]["playlistId"] == "RDAMVMseed"
    assert providers.calls[0][0]["videoId"] == "seed"
    assert providers.calls[0][0]["params"] == "wAEB"
    resumed = Autoplay(providers, Store(store.path)).next(first["next_cursor"])
    assert resumed["mode"] == "radio"
    assert resumed["session_id"] == first["session_id"]
    assert engine.next(first["next_cursor"]) == resumed
    assert len(first["tracks"] + resumed["tracks"]) == 6


def test_queue_api_separates_autoplay_radio_and_station(tmp_path):
    provider = FakeProviders()
    provider.stations = lambda: [{"id": "RDpersonal", "title": "My Mix"}]
    settings = Settings(tmp_path)
    with TestClient(create_app(settings, provider), base_url="http://localhost") as client:
        auth = {"Authorization": "Bearer " + settings.device_token()}
        for body, expected in [
            ({"video_id": "seed", "mode": "autoplay"}, "autoplay"),
            ({"video_id": "seed", "mode": "radio"}, "radio"),
            ({"playlist_id": "RDpersonal", "mode": "station"}, "station"),
        ]:
            first = client.post("/api/queues", headers=auth, json=body | {"limit": 3}).json()
            assert first["mode"] == expected
            cursor = {"cursor": first["next_cursor"]}
            second = client.post("/api/queues", headers=auth, json=cursor)
            assert second.status_code == 200 and second.json()["mode"] == expected
            assert client.post("/api/queues", headers=auth, json=cursor).json() == second.json()
            assert (
                client.post(
                    "/api/queues", headers=auth, json=cursor | {"mode": expected}
                ).status_code
                == 422
            )
        assert (
            client.post(
                "/api/queues", headers=auth, json={"mode": "station", "playlist_id": "other"}
            ).status_code
            == 422
        )


def test_order_and_context_continue_after_restart_without_regenerating(autoplay):
    engine, providers, store = autoplay
    first = engine.start("seed", limit=3)
    restarted = Autoplay(providers, Store(store.path))
    second = restarted.next(first["next_cursor"])
    third = restarted.next(second["next_cursor"])
    assert ids(first) + ids(second) + ids(third) == ["seed", *[f"seed-{x}" for x in range(1, 7)]]
    assert first["session_id"] == second["session_id"] == third["session_id"]
    assert len(providers.calls) == 3
    body, token = providers.calls[-1]
    assert token == "server-token-seed"
    assert body["params"] == "server-params-seed"
    assert not third["has_more"] and third["next_cursor"] is None


def test_same_cursor_retry_returns_identical_page_and_next_cursor(autoplay):
    engine, providers, _ = autoplay
    first = engine.start("seed", limit=3)
    cursor = first["next_cursor"]
    with ThreadPoolExecutor(max_workers=2) as pool:
        pages = list(pool.map(engine.next, [cursor, cursor]))
    assert pages[0] == pages[1]
    assert len(providers.calls) == 3


def test_failed_continuation_can_retry_without_losing_buffered_tracks(autoplay):
    engine, providers, _ = autoplay
    first = engine.start("seed", limit=3)
    providers.fail_next_continuation = True
    with pytest.raises(TimeoutError):
        engine.next(first["next_cursor"])
    retried = engine.next(first["next_cursor"])
    assert ids(retried) == ["seed-3", "seed-4", "seed-5"]


def test_missing_autoplay_endpoint_fails_without_radio_fallback(autoplay):
    engine, providers, _ = autoplay
    providers.autoplay_available = False
    with pytest.raises(ProviderUnavailable, match="did not offer Autoplay"):
        engine.start("seed")
    assert len(providers.calls) == 1


def test_duplicate_boundary_seed_is_not_queued_twice(autoplay):
    engine, providers, _ = autoplay
    providers.include_seed_again = True
    assert ids(engine.start("seed", limit=3)) == ["seed", "seed-1", "seed-2"]


def test_repeated_continuation_is_visible_and_not_consumed(autoplay):
    engine, providers, store = autoplay
    first = engine.start("seed", limit=3)
    providers.repeat_token = True
    with pytest.raises(ProviderUnavailable, match="repeated"):
        engine.next(first["next_cursor"])
    state, cached = store.autoplay_page(first["next_cursor"])
    assert cached is None
    assert [track["video_id"] for track in state["pending"]] == ["seed-3", "seed-4"]


def test_interleaved_song_sessions_keep_their_own_context(autoplay):
    engine, providers, _ = autoplay
    first_a = engine.start("a", limit=3)
    first_b = engine.start("b", limit=3)
    assert first_a["session_id"] != first_b["session_id"]
    assert ids(engine.next(first_a["next_cursor"])) == ["a-3", "a-4", "a-5"]
    assert ids(engine.next(first_b["next_cursor"])) == ["b-3", "b-4", "b-5"]
    assert providers.calls[-1][0]["params"] == "server-params-b"


def test_unsupported_queue_layout_is_not_reported_as_success(autoplay):
    engine, providers, _ = autoplay
    providers.watch_next = lambda *_: {"contents": {"unknownRenderer": {}}}
    with pytest.raises(ProviderUnavailable, match="unsupported"):
        engine.start("seed")


def test_unknown_cursor_is_not_a_new_radio(autoplay):
    engine, providers, _ = autoplay
    with pytest.raises(KeyError):
        engine.next(str(uuid4()))
    assert providers.calls == []


def test_provider_request_mutation_does_not_modify_saved_context(tmp_path, monkeypatch):
    providers = Providers(Settings(tmp_path))
    calls = []

    class YouTube:
        def _send_request(self, endpoint, body, additional=""):
            calls.append((endpoint, deepcopy(body), additional))
            body["context"] = {"mutation": True}
            return {}

    monkeypatch.setattr(providers, "yt", YouTube)
    body = {"playlistId": "returned", "params": "original"}
    providers.watch_next(body, "continuation-token")
    assert body == {"playlistId": "returned", "params": "original"}
    assert calls[0][2] == "&ctoken=continuation-token&continuation=continuation-token"


def test_authenticated_api_supports_autoplay_and_saved_cursor(tmp_path):
    settings = Settings(tmp_path)
    providers = FakeProviders()
    app = create_app(settings, providers)
    headers = {"Authorization": "Bearer " + settings.device_token()}
    with TestClient(app, base_url="http://localhost") as client:
        assert client.post("/api/autoplay", json={"video_id": "seed"}).status_code == 401
        first = client.post("/api/autoplay", headers=headers, json={"video_id": "seed", "limit": 3})
        assert first.status_code == 200
        assert ids(first.json()) == ["seed", "seed-1", "seed-2"]
        second = client.post(
            "/api/autoplay", headers=headers, json={"cursor": first.json()["next_cursor"]}
        )
        assert second.status_code == 200
        assert ids(second.json()) == ["seed-3", "seed-4", "seed-5"]
        assert app.state.store.report()["evidence"][-1]["kind"] == "song_autoplay"
        assert app.state.store.report()["totals"]["listened_seconds"] == 0
        assert app.state.store.submissions() == []


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"video_id": "seed", "cursor": str(uuid4())},
        {"video_id": "seed", "limit": 0},
        {"video_id": ""},
        {"cursor": "not-a-uuid"},
        {"cursor": str(uuid4()), "limit": 25},
    ],
)
def test_api_rejects_invalid_autoplay_input_before_provider_calls(tmp_path, body):
    settings = Settings(tmp_path)
    providers = FakeProviders()
    with TestClient(create_app(settings, providers), base_url="http://localhost") as client:
        result = client.post(
            "/api/autoplay",
            json=body,
            headers={"Authorization": "Bearer " + settings.device_token()},
        )
        assert result.status_code == 422
        assert providers.calls == []
