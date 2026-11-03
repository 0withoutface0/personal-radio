import pytest

from radio_prototype.matching import match_recording
from radio_prototype.playback import Outbox, PlaybackClock
from radio_prototype.store import Store


def track(**kwargs):
    return {
        "id": 1,
        "video_id": "song",
        "title": "Song",
        "artists": ["Artist"],
        "album": "Album",
        "duration": 180,
        "explicit": True,
        "isrc": None,
        **kwargs,
    }


@pytest.mark.parametrize(
    "title",
    [
        "Song (Live)",
        "Song (Club Remix)",
        "Song (Acoustic)",
        "Song (Radio Edit)",
        "Song (Instrumental)",
    ],
)
def test_studio_does_not_match_other_recording_versions(title):
    assert match_recording(track(), [track(title=title)])["status"] == "skipped"


def test_known_live_and_remix_versions_match_only_the_same_version():
    for title in ("Song (Live at Wembley)", "Song (Artist Remix)"):
        result = match_recording(track(title=title), [track(), track(id=2, title=title)])
        assert result["track"]["id"] == 2


def test_clean_and_explicit_never_substitute():
    assert match_recording(track(), [track(explicit=False)])["status"] == "skipped"


def test_duration_or_artist_disagreement_skips():
    assert match_recording(track(), [track(duration=195)])["status"] == "skipped"
    assert match_recording(track(), [track(artists=["Cover Artist"])])["status"] == "skipped"


def test_two_unknown_recording_ids_are_ambiguous():
    assert match_recording(track(), [track(), track(id=2)])["status"] == "skipped"


def test_identifier_agreement_and_album_tiebreak():
    result = match_recording(track(isrc="GB1234567890"), [track(isrc="GB1234567890")])
    assert result["score"] == 1
    result = match_recording(track(), [track(album="Compilation"), track(id=2)])
    assert result["track"]["id"] == 2


def test_no_candidates_are_visible_as_skipped():
    assert match_recording(track(), [])["status"] == "skipped"


def test_clock_excludes_pauses_buffering_and_seek_jumps():
    clock = PlaybackClock()
    clock.update("core-idle", False, 0)
    clock.update("time-pos", 0, 0)
    assert clock.update("time-pos", 1, 1) == 1
    clock.update("pause", True, 1)
    assert clock.update("time-pos", 1, 30) == 0
    clock.update("pause", False, 31)
    clock.update("time-pos", 1, 31)
    assert clock.update("time-pos", 2, 32) == 1
    clock.update("paused-for-cache", True, 32)
    clock.update("time-pos", 2, 45)
    clock.update("paused-for-cache", False, 45)
    clock.update("time-pos", 2, 46)
    assert clock.update("time-pos", 100, 47) == 0
    clock.update("seeking", True, 47)
    clock.update("seeking", False, 48)
    clock.update("time-pos", 50, 48)
    assert clock.update("time-pos", 51, 49) == 1
    assert clock.total == 3
    assert clock.coverage() == 3


def test_long_process_suspension_and_mute_do_not_count():
    clock = PlaybackClock()
    clock.update("core-idle", False, 0)
    clock.update("time-pos", 0, 0)
    assert clock.update("time-pos", 40, 40) == 0
    clock.update("mute", True, 40)
    assert clock.update("time-pos", 41, 41) == 0


def test_repeated_audio_counts_listening_but_not_full_recording_coverage():
    clock = PlaybackClock()
    clock.update("core-idle", False, 0)
    for base in (0, 5):
        clock.update("seeking", True, base)
        clock.update("seeking", False, base)
        clock.update("time-pos", 0, base)
        for second in range(1, 4):
            clock.update("time-pos", second, base + second)
    assert clock.total == 6
    assert clock.coverage() == 3


def test_outbox_keeps_same_id_when_acknowledgement_is_lost(tmp_path):
    store = Store(tmp_path / "server.sqlite3")
    occurrence_id = store.occurrence(track(), "song")
    outbox = Outbox(tmp_path / "client.sqlite3")
    outbox.add(occurrence_id, 2)

    class Client:
        fail = True
        ids = []

        def call(self, path, payload):
            self.ids.append(payload["id"])
            store.event(
                payload["id"], payload["occurrence_id"], payload["seconds"], payload["completed"]
            )
            if self.fail:
                self.fail = False
                raise RuntimeError("Lost acknowledgement")

    client = Client()
    with pytest.raises(RuntimeError):
        outbox.flush(client)
    Outbox(outbox.path).flush(client)
    assert len(client.ids) == 2 and client.ids[0] == client.ids[1]
    assert store.get_occurrence(occurrence_id)["listened"] == 2
