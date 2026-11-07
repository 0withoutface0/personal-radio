import json
from uuid import uuid4

import pytest

from radio_prototype.history_transfer import Archive, export_page, merge_archive
from radio_prototype.store import Store


def test_history_transfer_is_idempotent_and_has_no_provider_writes(tmp_path):
    original = Store(tmp_path / "one.sqlite3")
    replica = Store(tmp_path / "two.sqlite3")
    occurrence = original.occurrence(
        {"id": 11, "title": "Fixture", "artists": ["Artist"], "duration": 90}, "youtube"
    )
    for _ in range(7):
        original.event(str(uuid4()), occurrence, 5, played_at="2026-01-04T11:30:00+00:00")
    data = export_page(original, 0, None, True)
    archive = Archive.model_validate(data["archive"])
    assert merge_archive(replica, archive) == 7
    assert merge_archive(replica, archive) == 0
    assert replica.report()["totals"]["listened_seconds"] == 35
    assert replica.submissions() == []
    assert export_page(replica, 0, None, True)["archive"]["events"] == []
    assert len(export_page(replica, 0, None, False)["archive"]["events"]) == 7
    assert "youtube" not in json.dumps(data)
    with pytest.raises(ValueError):
        replica.event(str(uuid4()), occurrence, 3)
    bad = data["archive"]
    bad["events"].insert(0, bad["events"][0] | {"id": str(uuid4())})
    bad["events"][1]["seconds"] = 1
    with pytest.raises(ValueError):
        merge_archive(replica, Archive.model_validate(bad))
    assert replica.report()["totals"]["listened_seconds"] == 35
