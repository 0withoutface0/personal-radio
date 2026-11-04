from types import SimpleNamespace
from uuid import uuid4

import pytest

from radio_prototype.config import Settings
from radio_prototype.providers import Providers, ProviderUnavailable
from radio_prototype.reporting import Reporter
from radio_prototype.store import Store


class Accounts:
    def __init__(self):
        self.youtube_ready = self.tidal_ready = True
        self.timeout = self.reject = False
        self.youtube_writes = []
        self.tidal_writes = []
        self.favorite = False

    def yt(self):
        if not self.youtube_ready:
            raise ProviderUnavailable("Reconnect YouTube")

    def td(self):
        if not self.tidal_ready:
            raise ProviderUnavailable("Reconnect Tidal")

    def rate(self, video_id, value):
        self.youtube_writes.append((video_id, value))

    def check_rating(self, video_id, value):
        return value == "LIKE"

    def set_tidal_favorite(self, track_id, favorite):
        self.tidal_writes.append((track_id, favorite))
        if self.timeout:
            raise TimeoutError("secret upstream URL")
        if self.reject:
            return False
        self.favorite = favorite
        return True

    def check_tidal_favorite(self, track_id, favorite):
        return self.favorite == favorite


@pytest.fixture
def setup(tmp_path):
    store = Store(tmp_path / "radio.sqlite3")
    occurrence = store.occurrence(
        {"id": 42, "title": "Song", "artists": ["Artist"], "duration": 180}, "video"
    )
    accounts = Accounts()
    return store, occurrence, accounts, Reporter(store, accounts)


def test_one_like_schedules_both_targets_once_even_after_restart(setup):
    store, occurrence, accounts, reporter = setup
    event = str(uuid4())
    for _ in range(2):
        store.schedule_rating(occurrence, "LIKE", event, tidal_favorite=True)
    assert len(store.submissions()) == 2
    assert {r["provider"] for r in store.submissions()} == {"youtube", "tidal"}
    reporter.flush()
    Reporter(Store(store.path), accounts).flush()
    assert accounts.youtube_writes == [("video", "LIKE")]
    assert accounts.tidal_writes == [(42, True)]
    assert all(r["state"] == "visible" for r in store.submissions())


@pytest.mark.parametrize("offline", ["youtube", "tidal"])
def test_each_provider_can_succeed_while_the_other_is_offline(setup, offline):
    store, occurrence, accounts, reporter = setup
    setattr(accounts, offline + "_ready", False)
    store.schedule_rating(occurrence, "LIKE", str(uuid4()))
    reporter.flush()
    states = {r["provider"]: r["state"] for r in store.submissions()}
    assert states[offline] == "pending"
    assert states["tidal" if offline == "youtube" else "youtube"] == "visible"
    setattr(accounts, offline + "_ready", True)
    reporter.flush()
    assert len(accounts.youtube_writes) == len(accounts.tidal_writes) == 1
    assert all(r["state"] == "visible" for r in store.submissions())


@pytest.mark.parametrize("failure", ["timeout", "reject"])
def test_ambiguous_tidal_outcomes_are_not_resent(setup, failure):
    store, occurrence, accounts, reporter = setup
    setattr(accounts, failure, True)
    store.schedule_rating(occurrence, "LIKE", str(uuid4()))
    reporter.flush()
    Reporter(Store(store.path), accounts).flush()
    assert len(accounts.youtube_writes) == len(accounts.tidal_writes) == 1
    tidal = next(r for r in store.submissions() if r["provider"] == "tidal")
    assert tidal["state"] == "uncertain"
    assert "secret" not in tidal["detail"]
    accounts.favorite = True
    reporter.reconcile()
    assert next(r for r in store.submissions() if r["provider"] == "tidal")["state"] == "visible"
    assert len(accounts.tidal_writes) == 1


def test_clearing_like_removes_both_and_uses_new_action_ids(setup):
    store, occurrence, accounts, reporter = setup
    store.schedule_rating(occurrence, "LIKE", str(uuid4()))
    reporter.flush()
    event = str(uuid4())
    store.schedule_rating(occurrence, "INDIFFERENT", event, tidal_favorite=False)
    store.schedule_rating(occurrence, "INDIFFERENT", event, tidal_favorite=False)
    reporter.flush()
    assert accounts.youtube_writes == [("video", "LIKE"), ("video", "INDIFFERENT")]
    assert accounts.tidal_writes == [(42, True), (42, False)]
    assert not accounts.favorite


def test_dislike_alone_does_not_remove_preexisting_tidal_favorites(setup):
    store, occurrence, accounts, reporter = setup
    accounts.favorite = True
    store.schedule_rating(occurrence, "DISLIKE", str(uuid4()))
    reporter.flush()
    assert accounts.youtube_writes == [("video", "DISLIKE")]
    assert accounts.tidal_writes == []
    assert accounts.favorite


def test_latest_explicit_choice_supersedes_unsent_older_choices(setup):
    store, occurrence, accounts, reporter = setup
    store.schedule_rating(occurrence, "LIKE", str(uuid4()))
    store.schedule_rating(occurrence, "INDIFFERENT", str(uuid4()), tidal_favorite=False)
    store.schedule_rating(occurrence, "LIKE", str(uuid4()))
    assert len([r for r in store.submissions() if r["state"] == "superseded"]) == 4
    reporter.flush()
    assert accounts.youtube_writes == [("video", "LIKE")]
    assert accounts.tidal_writes == [(42, True)]


def test_preflight_failure_cannot_revive_a_superseded_action(setup):
    store, occurrence, accounts, reporter = setup
    store.schedule_rating(occurrence, "LIKE", str(uuid4()))

    def concurrent_new_choice():
        store.schedule_rating(occurrence, "INDIFFERENT", str(uuid4()), tidal_favorite=False)
        raise ProviderUnavailable("Account unavailable")

    accounts.yt = concurrent_new_choice
    reporter.flush()
    rows = store.submissions()
    assert rows[0]["state"] == rows[1]["state"] == "superseded"
    assert accounts.youtube_writes == accounts.tidal_writes == []


def test_legacy_submitted_likes_are_not_backfilled_to_tidal(setup):
    store, occurrence, accounts, reporter = setup
    with store.connect() as db:
        store._schedule(db, occurrence, "rating:old", "LIKE")
    reporter.flush()
    assert accounts.youtube_writes == [("video", "LIKE")]
    assert accounts.tidal_writes == []


def test_retry_cannot_add_new_tidal_intent_to_an_existing_action(setup):
    store, occurrence, _, _ = setup
    event = str(uuid4())
    store.schedule_rating(occurrence, "INDIFFERENT", event)
    with pytest.raises(ValueError, match="different Tidal intent"):
        store.schedule_rating(occurrence, "INDIFFERENT", event, tidal_favorite=False)
    with pytest.raises(ValueError):
        store.schedule_rating(occurrence, "LIKE", event, tidal_favorite=True)
    assert len(store.submissions()) == 1


def test_tidal_adapter_uses_the_matched_track_id_and_persists_rotated_session(tmp_path):
    calls = []
    session = SimpleNamespace(
        user=SimpleNamespace(
            favorites=SimpleNamespace(
                add_track=lambda track_id: calls.append(("add", track_id)) or True,
                remove_track=lambda track_id: calls.append(("remove", track_id)) or True,
            )
        ),
        save_session_to_file=lambda path: calls.append(("save", path)),
    )
    provider = Providers(Settings(tmp_path))
    provider.td = lambda: session
    assert provider.set_tidal_favorite(42, True)
    assert provider.set_tidal_favorite(42, False)
    assert calls == [
        ("add", "42"),
        ("save", tmp_path / "tidal-pkce.json"),
        ("remove", "42"),
        ("save", tmp_path / "tidal-pkce.json"),
    ]


def test_favorite_verification_checks_later_pages_and_never_hides_read_failures(tmp_path):
    calls = []

    def tracks(*, limit, offset):
        calls.append((limit, offset))
        return (
            [SimpleNamespace(id=i) for i in range(100)]
            if offset == 0
            else [SimpleNamespace(id=200)]
        )

    provider = Providers(Settings(tmp_path))
    provider.td = lambda: SimpleNamespace(
        user=SimpleNamespace(favorites=SimpleNamespace(tracks=tracks))
    )
    assert provider.check_tidal_favorite(200, True)
    assert calls == [(100, 0), (100, 100)]
    assert provider.check_tidal_favorite(201, False)

    def unavailable(**kwargs):
        raise TimeoutError()

    provider.td = lambda: SimpleNamespace(
        user=SimpleNamespace(favorites=SimpleNamespace(tracks=unavailable))
    )
    with pytest.raises(TimeoutError):
        provider.check_tidal_favorite(201, False)
