from copy import deepcopy
from types import SimpleNamespace

import pytest

from radio_prototype.config import Settings
from radio_prototype.matching import audio_reference, match_recording, normalize
from radio_prototype.providers import Providers, youtube_track


def recording(**values):
    return {
        "id": 1,
        "video_id": "video",
        "title": "Song",
        "artists": ["Artist"],
        "album": "Single",
        "duration": 180,
        "explicit": True,
        "isrc": "GB1234567890",
        **values,
    }


def youtube(**values):
    return {
        "videoId": "audio",
        "title": "Song",
        "artists": [{"name": "Artist"}],
        "album": {"name": "Single"},
        "duration_seconds": 180,
        "isExplicit": True,
        "videoType": "MUSIC_VIDEO_TYPE_ATV",
        **values,
    }


def provider(tmp_path, *, songs=(), candidates=(), seed=None):
    p = Providers(Settings(tmp_path))
    p.yt = lambda: SimpleNamespace(
        search=lambda *a, **kw: list(songs),
        get_watch_playlist=lambda **kw: {"tracks": [seed] if seed else []},
    )
    p.candidates = lambda source: list(candidates)
    return p


def test_counterpart_survives_parser_without_private_provider_fields():
    raw = youtube(videoId="video", videoType="MUSIC_VIDEO_TYPE_OMV", duration_seconds=302)
    raw["counterpart"] = youtube(duration_seconds=275, feedbackTokens={"private": "value"})
    track = youtube_track(raw)
    assert track["video_id"] == "video"
    assert track["video_type"] == "MUSIC_VIDEO_TYPE_OMV"
    assert track["counterpart"]["video_id"] == "audio"
    assert track["counterpart"]["duration"] == 275
    assert "feedbackTokens" not in track["counterpart"]


def test_linked_audio_duration_is_used_without_replacing_recommendation_identity(tmp_path):
    source = recording(duration=400, video_type="MUSIC_VIDEO_TYPE_OMV", isrc=None)
    source["counterpart"] = recording(video_id="audio", video_type="MUSIC_VIDEO_TYPE_ATV")
    original = deepcopy(source)
    result = provider(tmp_path, candidates=[recording()]).match(source)
    assert result["status"] == "matched"
    assert result["method"] == "youtube_counterpart"
    assert result["audio_source"]["video_id"] == "audio"
    assert source == original


def test_legacy_queue_recovers_provider_counterpart(tmp_path):
    source = recording(album=None, duration=302, isrc=None)
    seed = youtube(videoId="video", videoType="MUSIC_VIDEO_TYPE_OMV")
    seed["counterpart"] = youtube()
    result = provider(tmp_path, seed=seed, candidates=[recording()]).match(source)
    assert result["status"] == "matched"
    assert result["method"] == "youtube_counterpart"


def test_video_runtime_resolves_through_official_song_not_widened_tidal_tolerance(tmp_path):
    source = recording(duration=302, video_type="MUSIC_VIDEO_TYPE_OMV", isrc=None)
    target = recording(duration=274)
    assert match_recording(source, [target])["status"] == "skipped"
    p = provider(tmp_path, songs=[youtube(duration_seconds=275)], candidates=[target])
    result = p.match(source)
    assert result["status"] == "matched"
    assert result["method"] == "youtube_song_metadata"
    assert result["audio_source"]["duration"] == 275
    assert source["duration"] == 302


@pytest.mark.parametrize(
    "changes",
    [
        {"title": "Song (Live)"},
        {"title": "Song (Artist Remix)"},
        {"artists": ["Cover Artist"]},
        {"explicit": False},
        {"isrc": "GB9999999999"},
        {"video_type": "MUSIC_VIDEO_TYPE_OMV"},
    ],
)
def test_counterpart_cannot_override_recording_conflicts(tmp_path, changes):
    source = recording(duration=302, video_type="MUSIC_VIDEO_TYPE_OMV")
    source["counterpart"] = recording(**{"video_type": "MUSIC_VIDEO_TYPE_ATV", **changes})
    p = provider(tmp_path, candidates=[recording(duration=180)])
    result = p.match(source)
    assert result.get("method") != "youtube_counterpart"
    assert "audio_source" not in result


def test_audio_source_never_switches_to_its_video_counterpart(tmp_path):
    source = recording(video_type="MUSIC_VIDEO_TYPE_ATV")
    source["counterpart"] = recording(duration=400, video_type="MUSIC_VIDEO_TYPE_OMV")
    result = provider(tmp_path, candidates=[recording()]).match(source)
    assert result["status"] == "matched"
    assert "audio_source" not in result


@pytest.mark.parametrize("field,value", [("explicit", False), ("isrc", "GB9999999999")])
def test_audio_enrichment_preserves_known_source_constraints(tmp_path, field, value):
    source = recording(duration=302, video_type="MUSIC_VIDEO_TYPE_OMV")
    source["counterpart"] = recording(video_type="MUSIC_VIDEO_TYPE_ATV", explicit=None, isrc=None)
    candidate = recording(**{field: value})
    result = provider(tmp_path, candidates=[candidate]).match(source)
    assert result["status"] == "skipped"
    assert result["audio_source"][field] == source[field]


def test_search_resolution_is_bounded_and_still_requires_strict_audio_duration(tmp_path):
    source = recording(duration=302, video_type="MUSIC_VIDEO_TYPE_OMV", isrc=None)
    assert not audio_reference(source, recording(duration=180))
    p = provider(
        tmp_path, songs=[youtube(duration_seconds=275)], candidates=[recording(duration=280)]
    )
    assert p.match(source)["status"] == "skipped"


def test_ambiguous_recordings_stay_ambiguous_after_resolving_video(tmp_path):
    source = recording(duration=199, video_type="MUSIC_VIDEO_TYPE_OMV", isrc=None, album=None)
    targets = [recording(album="Album A"), recording(id=2, isrc="GB9999999999", album="Album B")]
    result = provider(
        tmp_path, songs=[youtube(album={"name": "Other album"})], candidates=targets
    ).match(source)
    assert result["status"] == "skipped"
    assert "Ambiguous" in result["reason"]
    assert all(c["rejection"] is None for c in result["candidates"])


def test_search_does_not_choose_first_of_conflicting_audio_references(tmp_path):
    source = recording(duration=199, video_type="MUSIC_VIDEO_TYPE_OMV", isrc=None, explicit=None)
    songs = [youtube(), youtube(videoId="clean", isExplicit=False)]
    targets = [recording(), recording(id=2, explicit=False, isrc="GB9999999999")]
    result = provider(tmp_path, songs=songs, candidates=targets).match(source)
    assert result["status"] == "skipped"
    assert "Ambiguous" in result["reason"]


def test_video_labels_and_soundtrack_attribution_are_not_recording_versions():
    for title in (
        "Song (Official Video)",
        "Song [Lyric Video]",
        'Song (from the Series "Example")',
    ):
        assert match_recording(recording(title=title), [recording()])["status"] == "matched"
    assert normalize("Beyonc\u00e9") == normalize("Beyonce")


def test_featured_artists_must_be_accounted_for_on_both_sides():
    source = recording(title="Song (feat. Guest)", isrc=None)
    good = recording(title="Song", artists=["Artist", "Guest"])
    assert match_recording(source, [good])["status"] == "matched"
    assert match_recording(source, [recording()])["status"] == "skipped"
    assert (
        match_recording(source, [recording(artists=["Artist", "Other Guest"])])["status"]
        == "skipped"
    )


def test_artist_first_search_recovers_tracks_missing_from_first_page(tmp_path):
    p = Providers(Settings(tmp_path))
    calls = []

    def search(query, **kwargs):
        calls.append(query)
        t = recording(title="Wrong song" if len(calls) == 1 else "Song")
        return {
            "tracks": [
                SimpleNamespace(
                    id=t["id"],
                    name=t["title"],
                    version=None,
                    artists=[SimpleNamespace(name=a) for a in t["artists"]],
                    album=SimpleNamespace(name=t["album"]),
                    duration=t["duration"],
                    explicit=t["explicit"],
                    isrc=t["isrc"],
                )
            ]
        }

    p.td = lambda: SimpleNamespace(search=search)
    source = recording(isrc=None)
    candidates = p.candidates(source)
    assert calls == ['"song" "Artist"', "Artist song"]
    assert match_recording(source, candidates)["status"] == "matched"
