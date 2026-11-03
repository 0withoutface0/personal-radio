from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

import pytest

from radio_prototype.reporting import Reporter
from radio_prototype.store import Store


@pytest.fixture
def store(tmp_path):
    return Store(tmp_path / "radio.sqlite3")


def occurrence(store, duration=180, video="youtube-song"):
    return store.occurrence(
        {"id": 1, "title": "Song", "artists": ["Artist"], "duration": duration}, video
    )


def add_time(store, track, seconds):
    while seconds:
        interval = min(5, seconds)
        store.event(str(uuid4()), track, interval)
        seconds -= interval


def test_retries_are_idempotent_and_conflicts_rejected(store):
    track = occurrence(store)
    event = str(uuid4())
    assert store.event(event, track, 5)
    assert not store.event(event, track, 5)
    with pytest.raises(ValueError):
        store.event(event, track, 4)
    assert store.get_occurrence(track)["listened"] == 5


def test_concurrent_events_schedule_history_once(store):
    track = occurrence(store)
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda _: store.event(str(uuid4()), track, 1), range(50)))
    assert store.get_occurrence(track)["listened"] == 50
    assert len(store.submissions()) == 1


def test_threshold_excludes_early_skip_and_does_not_dislike(store):
    track = occurrence(store)
    add_time(store, track, 29)
    assert store.submissions() == []
    add_time(store, track, 1)
    assert [x["kind"] for x in store.submissions()] == ["history"]


def test_natural_short_completion_requires_whole_track(store):
    track = occurrence(store, duration=12)
    add_time(store, track, 4)
    store.event(str(uuid4()), track, 0, completed=True)
    assert not store.submissions()
    add_time(store, track, 8)
    store.event(str(uuid4()), track, 0, completed=True)
    assert len(store.submissions()) == 1


def test_local_only_occurrence_does_not_schedule_history(store):
    track = occurrence(store, video=None)
    add_time(store, track, 30)
    assert not store.submissions()


def test_restart_preserves_totals_corrections_and_ambiguous_outcomes(store):
    track = occurrence(store)
    add_time(store, track, 30)
    store.correction("source", 42)
    assert store.claim(store.submissions()[0]["id"], [])
    restarted = Store(store.path)
    assert restarted.get_occurrence(track)["listened"] == 30
    assert restarted.correction("source") == 42
    assert restarted.submissions()[0]["state"] == "uncertain"


class FakeYouTube:
    def __init__(self, *, timeout=False, preexisting=False, visible=True):
        self.timeout = timeout
        self.preexisting = preexisting
        self.make_visible = visible
        self.writes = 0
        self.ratings = []

    def yt(self):
        return self

    def history(self):
        return (
            [{"videoId": "youtube-song"}]
            if self.preexisting or (self.writes and self.make_visible)
            else []
        )

    def submit_history(self, video_id):
        self.writes += 1
        if self.timeout:
            raise TimeoutError("Sensitive upstream URL should never be retained")
        return 204

    def rate(self, video_id, value):
        self.ratings.append((video_id, value))
        return None

    def check_rating(self, video_id, value):
        return value == "LIKE"


def test_new_history_is_verified_after_successful_write(store):
    add_time(store, occurrence(store), 30)
    provider = FakeYouTube()
    reporter = Reporter(store, provider)
    reporter.flush()
    reporter.flush()
    assert provider.writes == 1
    assert store.submissions()[0]["state"] == "visible"
    evidence = store.report()["evidence"][-1]
    assert evidence["kind"] == "history_visibility"
    assert evidence["status"] == "passed"
    assert store.report()["recap"] == "unverified"


def test_old_history_does_not_prove_a_new_play(store):
    add_time(store, occurrence(store), 30)
    Reporter(store, FakeYouTube(preexisting=True)).flush()
    assert store.report()["evidence"][-1]["status"] == "uncertain"
    assert "history_visibility" in store.report()["missing_evidence"]


def test_ambiguous_mutation_is_never_blindly_retried(store):
    add_time(store, occurrence(store), 30)
    provider = FakeYouTube(timeout=True, visible=False)
    Reporter(store, provider).flush()
    restarted = Store(store.path)
    Reporter(restarted, provider).flush()
    assert provider.writes == 1
    assert restarted.submissions()[0]["state"] == "uncertain"
    assert "Sensitive" not in restarted.submissions()[0]["detail"]


def test_visibility_check_failure_does_not_repeat_successful_write(store):
    add_time(store, occurrence(store), 30)
    provider = FakeYouTube(visible=False)
    reporter = Reporter(store, provider)
    reporter.flush()
    reporter.flush()
    assert provider.writes == 1
    assert store.submissions()[0]["state"] == "submitted"


def test_explicit_rating_is_sent_once_and_dislike_visibility_stays_uncertain(store):
    track = occurrence(store)
    store.schedule_rating(track, "DISLIKE")
    store.schedule_rating(track, "DISLIKE")
    with pytest.raises(ValueError):
        store.schedule_rating(track, "LIKE")
    provider = FakeYouTube()
    reporter = Reporter(store, provider)
    reporter.flush()
    reporter.flush()
    assert provider.ratings == [("youtube-song", "DISLIKE")]
    assert store.submissions()[0]["state"] == "submitted"


def test_library_get_song_and_history_call_use_same_instance(tmp_path, monkeypatch):
    from radio_prototype.config import Settings
    from radio_prototype.providers import Providers

    providers = Providers(Settings(tmp_path))
    song = {"playbackTracking": {"fake": True}}

    class YouTube:
        def get_song(self, video_id):
            assert video_id == "song"
            return song

        def add_history_item(self, received):
            assert received is song
            return type("Response", (), {"status_code": 204})()

    monkeypatch.setattr(providers, "yt", lambda: YouTube())
    assert providers.submit_history("song") == 204
