from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from radio_prototype.api import create_app
from radio_prototype.config import Settings
from radio_prototype.providers import Providers


@pytest.fixture
def catalog_api(tmp_path):
    settings = Settings(tmp_path)
    settings.youtube_file.write_text("{}", encoding="utf-8")
    providers = Providers(settings)
    calls = []

    def search(query, *, filter, limit):
        calls.append(("search", query, filter, limit))
        return {
            "songs": [
                {
                    "videoId": "audio",
                    "title": "Song",
                    "artists": [{"name": "Artist", "id": "UC1"}],
                    "album": {"name": "Record", "id": "MPRE1"},
                }
            ],
            "artists": [{"browseId": "UC1", "artist": "Artist", "thumbnails": [{"url": "art"}]}],
            "albums": [{"browseId": "MPRE1", "title": "Record", "year": "2026"}],
        }[filter]

    def artist(artist_id):
        calls.append(("artist", artist_id))
        return {
            "name": "Artist",
            "channelId": "different-subscription-id",
            "songs": {"results": [{"videoId": "audio", "title": "Song", "album": "Record"}]},
            "albums": {
                "browseId": "release-shelf",
                "params": "server-only-params",
                "results": [{"browseId": "MPRE1", "title": "Record"}],
            },
            "singles": {"results": [{"browseId": "MPRE2", "title": "Single"}]},
        }

    def albums(browse_id, params, *, limit):
        calls.append(("albums", browse_id, params, limit))
        return [{"browseId": f"MPRE{x}", "title": f"Record {x}"} for x in range(limit)]

    providers.youtube = SimpleNamespace(
        search=search,
        get_artist=artist,
        get_artist_albums=albums,
        get_album=lambda _: {
            "title": "Record",
            "artists": [{"name": "Artist", "id": "UC1"}],
            "thumbnails": [{"url": "small"}, {"url": "large"}],
            "tracks": [
                {
                    "videoId": "one",
                    "title": "First",
                    "album": "Record",
                    "duration": "3:05",
                    "isExplicit": True,
                },
                {"videoId": "two", "title": "Second", "isAvailable": False},
                {"videoId": None, "title": "Unavailable"},
            ],
        },
    )
    app = create_app(settings, providers)
    with TestClient(app, base_url="http://localhost") as client:
        yield client, app.state.store, {"Authorization": "Bearer " + settings.device_token()}, calls


def test_catalog_search_types_and_navigation_ids(catalog_api):
    client, store, auth, calls = catalog_api
    song = client.get("/api/catalog/search?q=Song", headers=auth).json()["items"][0]
    assert song["video_id"] == "audio"
    assert song["album_id"] == "MPRE1"
    assert song["artist_refs"] == [{"id": "UC1", "name": "Artist"}]
    for kind, expected in (("artists", "UC1"), ("albums", "MPRE1")):
        result = client.get(f"/api/catalog/search?q=Artist&kind={kind}", headers=auth)
        assert result.json()["items"][0]["id"] == expected
    assert calls[0] == ("search", "Song", "songs", 30)
    assert store.report()["totals"]["occurrences"] == 0
    assert store.report()["submissions"] == []


def test_album_normalization_keeps_order_availability_and_browsing_links(catalog_api):
    client, _, auth, _ = catalog_api
    album = client.get("/api/catalog/albums/MPRE1", headers=auth).json()
    assert album["id"] == "MPRE1"
    first, second, missing = album["tracks"]
    assert [t["track_number"] for t in album["tracks"]] == [1, 2, 3]
    assert first["duration"] == 185
    assert first["album"] == "Record"
    assert first["album_id"] == "MPRE1"
    assert first["artists"] == ["Artist"]
    assert first["explicit"] is True
    assert first["artwork"] == "large"
    assert first["available"] is True
    assert second["available"] is False
    assert missing["available"] is False


def test_artist_releases_keep_browse_identity_and_provider_params_on_server(catalog_api):
    client, _, auth, calls = catalog_api
    artist = client.get("/api/catalog/artists/UC1", headers=auth).json()
    assert artist["id"] == "UC1"
    assert artist["songs"][0]["artist_refs"] == [{"id": "UC1", "name": "Artist"}]
    assert artist["songs"][0]["album"] == "Record"
    assert artist["releases"]["albums"][0]["id"] == "MPRE1"
    result = client.get("/api/catalog/artists/UC1/releases?limit=2", headers=auth).json()
    assert result["has_more"]
    assert calls[-1] == ("albums", "release-shelf", "server-only-params", 2)
    assert "server-only-params" not in str(result)
    singles = client.get("/api/catalog/artists/UC1/releases?kind=singles", headers=auth).json()
    assert not singles["has_more"]
    assert singles["items"][0]["id"] == "MPRE2"
    capped = client.get("/api/catalog/artists/UC1/releases?limit=1000", headers=auth).json()
    assert capped["limited"] and not capped["has_more"]


@pytest.mark.parametrize(
    "path",
    [
        "/api/catalog/search?q=x",
        "/api/catalog/artists/UC1",
        "/api/catalog/artists/UC1/releases",
        "/api/catalog/albums/MPRE1",
    ],
)
def test_catalog_requires_device_access_token(catalog_api, path):
    client, _, _, _ = catalog_api
    assert client.get(path).status_code == 401


@pytest.mark.parametrize(
    "path",
    [
        "/api/catalog/search?q=%20",
        "/api/catalog/search?q=x&kind=videos",
        "/api/catalog/artists/UC1/releases?kind=videos",
        "/api/catalog/artists/UC1/releases?limit=1001",
        "/api/catalog/artists/UC1/releases?limit=0",
    ],
)
def test_invalid_catalog_queries_are_rejected(catalog_api, path):
    client, _, auth, calls = catalog_api
    assert client.get(path, headers=auth).status_code == 422
    assert calls == []
