"""Home fixtures contain no account state or real provider playback requests."""

from copy import deepcopy
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from radio_prototype.api import create_app
from radio_prototype.config import Settings
from radio_prototype.local_accounts import LocalProviders
from radio_prototype.providers import Providers


def song(video_id="one"):
    target = {
        "videoId": video_id,
        "playlistId": "RDhome-" + video_id,
        "params": "server-only-context",
    }
    return {
        "musicTwoRowItemRenderer": {
            "title": {"runs": [{"text": "Song " + video_id}]},
            "subtitle": {
                "runs": [
                    {
                        "text": "Artist",
                        "navigationEndpoint": {"browseEndpoint": {"browseId": "UC1"}},
                    }
                ]
            },
            "navigationEndpoint": {"watchEndpoint": target},
            "thumbnailRenderer": {
                "musicThumbnailRenderer": {
                    "thumbnail": {"thumbnails": [{"url": "https://example.test/art.jpg"}]}
                }
            },
        }
    }


def browse(kind, id):
    return {
        "musicTwoRowItemRenderer": {
            "title": {
                "runs": [
                    {
                        "text": kind,
                        "navigationEndpoint": {
                            "browseEndpoint": {
                                "browseId": id,
                                "browseEndpointContextSupportedConfigs": {
                                    "browseEndpointContextMusicConfig": {
                                        "pageType": "MUSIC_PAGE_TYPE_" + kind.upper()
                                    }
                                },
                            }
                        },
                    }
                ]
            },
            "subtitle": {"runs": [{"text": "Artist"}]},
        }
    }


def shelf(title, items, play_all=False):
    header = {"title": {"runs": [{"text": title}]}}
    if play_all:
        header["moreContentButton"] = {
            "buttonRenderer": {
                "navigationEndpoint": {
                    "watchEndpoint": {"videoId": "one", "params": "private-multi-seed-context"}
                }
            }
        }
    return {
        "musicCarouselShelfRenderer": {
            "header": {"musicCarouselShelfBasicHeaderRenderer": header},
            "contents": items,
        }
    }


def page(rows, continuation=None):
    section = {"contents": rows}
    if continuation:
        section["continuations"] = [{"nextContinuationData": {"continuation": continuation}}]
    return {
        "contents": {
            "singleColumnBrowseResultsRenderer": {
                "tabs": [{"tabRenderer": {"content": {"sectionListRenderer": section}}}]
            }
        }
    }


@pytest.fixture(params=["server", "embedded"])
def home_api(tmp_path, request):
    settings = Settings(tmp_path)
    embedded = request.param == "embedded"
    if embedded:
        accounts = {"youtube": {"auth": {}, "identity": None}, "tidal": None}
        vault = SimpleNamespace(read=lambda name: accounts if name == "accounts" else None)
        providers = LocalProviders(settings, vault)
        token = "embedded-test"
    else:
        settings.youtube_file.write_text("{}", encoding="utf-8")
        providers = Providers(settings)
        token = settings.device_token()
    calls = []
    state = {
        "account": {"accountName": "Offline fixture"},
        "home": page(
            [
                shelf(
                    "Listen again",
                    [
                        song(),
                        browse("artist", "UC1"),
                        browse("album", "MPRE1"),
                        browse("playlist", "VLPL1"),
                    ],
                ),
                shelf("Quick picks", [song("two"), song("one")], play_all=True),
            ]
        ),
        "speed": page([]),
    }

    def request(endpoint, body, params=""):
        calls.append((endpoint, deepcopy(body), params))
        if params:
            return {
                "continuationContents": {"sectionListContinuation": {"contents": state["later"]}}
            }
        return deepcopy(
            state["speed" if body.get("browseId") == "FEmusic_listen_again" else "home"]
        )

    providers.youtube = SimpleNamespace(
        get_account_info=lambda: state["account"], _send_request=request
    )
    app = create_app(settings, providers, embedded=embedded, runtime_token=token)
    with TestClient(app, base_url="http://127.0.0.1") as client:
        yield client, app, {"Authorization": "Bearer " + token}, calls, state


def test_personal_shelves_preserve_order_types_and_hide_provider_commands(home_api):
    client, app, auth, calls, state = home_api
    result = client.get("/api/home", headers=auth)
    assert result.status_code == 200
    data = result.json()
    assert data["source"] == "youtube_music"
    assert [x["kind"] for x in data["speed_dial"]["items"]] == [
        "song",
        "artist",
        "album",
        "playlist",
    ]
    assert [x["song"]["video_id"] for x in data["quick_picks"]["items"]] == ["two", "one"]
    assert data["quick_picks"]["play_all_id"]
    assert "server-only-context" not in result.text
    assert "private-multi-seed-context" not in result.text
    assert "feedbackToken" not in result.text
    first = data["speed_dial"]["items"][0]
    endpoint, mode, title = app.state.home.playback(first["play_id"])
    assert endpoint["params"] == "server-only-context" and mode == "autoplay"
    assert title == "Song one"
    endpoint, mode, _ = app.state.home.playback(data["quick_picks"]["play_all_id"])
    assert endpoint == {"videoId": "one", "params": "private-multi-seed-context"}
    assert mode == "radio"
    assert app.state.store.report()["totals"]["occurrences"] == 0
    assert app.state.store.submissions() == []


def test_home_cache_refresh_and_old_visible_selections(home_api):
    client, app, auth, calls, state = home_api
    first = client.get("/api/home", headers=auth).json()
    count = len(calls)
    assert client.get("/api/home", headers=auth).json() == first
    assert len(calls) == count
    second = client.get("/api/home?refresh=true", headers=auth).json()
    assert len(calls) > count
    assert second["speed_dial"]["items"][0]["play_id"] != first["speed_dial"]["items"][0]["play_id"]
    assert app.state.home.playback(first["speed_dial"]["items"][0]["play_id"])


def test_continuation_and_dedicated_speed_dial_fallback(home_api):
    client, _, auth, calls, state = home_api
    state["home"] = page([shelf("Quick picks", [song()])], "private-home-token")
    state["later"] = [shelf("Other shelf", [song()])]
    state["speed"] = page([shelf("Listen again", [song("later")])])
    data = client.get("/api/home", headers=auth).json()
    assert data["speed_dial"]["items"][0]["song"]["video_id"] == "later"
    assert any("private-home-token" in params for _, _, params in calls)
    assert any(body["browseId"] == "FEmusic_listen_again" for _, body, _ in calls)


def test_missing_shelves_and_signed_out_feeds_are_explicit(home_api):
    client, _, auth, calls, state = home_api
    state["home"] = page([])
    data = client.get("/api/home", headers=auth).json()
    assert not data["speed_dial"]["available"] and data["speed_dial"]["message"]
    assert not data["quick_picks"]["available"] and data["quick_picks"]["items"] == []
    state["account"] = {}
    before = len(calls)
    response = client.get("/api/home?refresh=true", headers=auth)
    assert response.status_code == 503 and "sign-in" in response.json()["detail"]
    assert len(calls) == before


def test_expired_and_cross_account_targets_cannot_be_replayed(home_api):
    client, app, auth, _, state = home_api
    data = client.get("/api/home", headers=auth).json()
    key = data["quick_picks"]["play_all_id"]
    entry = app.state.home.targets[key]
    app.state.home.targets[key] = (-1, *entry[1:])
    assert (
        client.post("/api/home/play", headers=auth, json={"selection_id": key}).status_code == 503
    )
    providers = app.state.home.providers
    providers.youtube = SimpleNamespace(**vars(providers.youtube))
    key = data["speed_dial"]["items"][0]["play_id"]
    assert (
        client.post("/api/home/play", headers=auth, json={"selection_id": key}).status_code == 503
    )
    state["home"] = page([shelf("Listen again", [song("new-session")])])
    refreshed = client.get("/api/home", headers=auth).json()
    assert refreshed["speed_dial"]["items"][0]["song"]["video_id"] == "new-session"


@pytest.mark.parametrize(
    "method,path,body",
    [
        ("GET", "/api/home", None),
        ("POST", "/api/home/play", {"selection_id": "00000000-0000-0000-0000-000000000000"}),
    ],
)
def test_home_requires_device_access_token(home_api, method, path, body):
    client, _, _, _, _ = home_api
    assert client.request(method, path, json=body).status_code == 401


def test_reconnected_browser_credentials_reload_without_restarting_server(tmp_path, monkeypatch):
    import os

    import radio_prototype.providers as module

    settings = Settings(tmp_path)
    settings.youtube_file.write_text('{"fixture":"first"}', encoding="utf-8")
    created = []

    def youtube(path, *, requests_session):
        result = object()
        created.append(result)
        return result

    monkeypatch.setattr(module, "YTMusic", youtube)
    providers = Providers(settings)
    first = providers.yt()
    assert providers.yt() is first
    stamp = settings.youtube_file.stat().st_mtime_ns
    settings.youtube_file.write_text('{"fixture":"reconnected"}', encoding="utf-8")
    os.utime(settings.youtube_file, ns=(stamp + 1_000_000_000, stamp + 1_000_000_000))
    second = providers.yt()
    assert second is not first and providers.yt() is second
    assert len(created) == 2
