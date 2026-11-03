import json
import sqlite3
import time
from contextlib import contextmanager
from datetime import UTC, datetime
from uuid import uuid4


def now():
    return datetime.now(UTC).isoformat()


class Store:
    def __init__(self, path):
        self.path = path
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS occurrences (
                    id TEXT PRIMARY KEY, video_id TEXT, tidal_id INTEGER NOT NULL,
                    title TEXT NOT NULL, artist TEXT NOT NULL, duration REAL NOT NULL,
                    listened REAL NOT NULL DEFAULT 0, completed INTEGER NOT NULL DEFAULT 0,
                    created TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS events (
                    id TEXT PRIMARY KEY, occurrence_id TEXT NOT NULL REFERENCES occurrences(id),
                    seconds REAL NOT NULL, completed INTEGER NOT NULL, created TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS submissions (
                    id TEXT PRIMARY KEY, occurrence_id TEXT NOT NULL REFERENCES occurrences(id),
                    kind TEXT NOT NULL, value TEXT, state TEXT NOT NULL,
                    detail TEXT NOT NULL, created TEXT NOT NULL, updated TEXT NOT NULL,
                    baseline TEXT,
                    UNIQUE(occurrence_id,kind)
                );
                CREATE TABLE IF NOT EXISTS evidence (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL,
                    details TEXT NOT NULL, created TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS corrections (
                    video_id TEXT PRIMARY KEY, tidal_id INTEGER NOT NULL, created TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS autoplay_pages (
                    cursor TEXT PRIMARY KEY, session_id TEXT NOT NULL,
                    state TEXT NOT NULL, response TEXT, created TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS device_lease (
                    slot INTEGER PRIMARY KEY CHECK(slot=1), device_id TEXT NOT NULL,
                    expires REAL NOT NULL
                );
            """)
            columns = {row["name"] for row in db.execute("PRAGMA table_info(submissions)")}
            if "baseline" not in columns:
                db.execute("ALTER TABLE submissions ADD COLUMN baseline TEXT")
            # A process may have died after a request was accepted by YouTube.
            db.execute(
                "UPDATE submissions SET state='uncertain', detail=? WHERE state='sending'",
                ("Interrupted while submitting; reconcile without resending.",),
            )

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    def occurrence(self, track, video_id=None, occurrence_id=None):
        occurrence_id = occurrence_id or str(uuid4())
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            old = db.execute(
                "SELECT tidal_id,video_id FROM occurrences WHERE id=?", (occurrence_id,)
            ).fetchone()
            if old:
                if old["tidal_id"] != track["id"] or old["video_id"] != video_id:
                    raise ValueError("Occurrence ID reused with different recordings")
                return occurrence_id
            db.execute(
                "INSERT INTO occurrences VALUES (?,?,?,?,?,?,0,0,?)",
                (
                    occurrence_id,
                    video_id,
                    track["id"],
                    track["title"],
                    ", ".join(track["artists"]),
                    track["duration"],
                    now(),
                ),
            )
        return occurrence_id

    def get_occurrence(self, occurrence_id):
        with self.connect() as db:
            row = db.execute("SELECT * FROM occurrences WHERE id=?", (occurrence_id,)).fetchone()
        if not row:
            raise KeyError("Unknown occurrence")
        return dict(row)

    def event(self, event_id, occurrence_id, seconds, completed=False):
        if not 0 <= seconds <= 5:
            raise ValueError("Playback intervals must be between 0 and 5 seconds")
        with self.connect() as db:
            # Serializes event totals, deduplication, and threshold scheduling atomically.
            db.execute("BEGIN IMMEDIATE")
            old = db.execute("SELECT * FROM events WHERE id=?", (event_id,)).fetchone()
            if old:
                if (old["occurrence_id"], old["seconds"], bool(old["completed"])) != (
                    occurrence_id,
                    seconds,
                    completed,
                ):
                    raise ValueError("Event ID reused with a different payload")
                return False
            track = db.execute("SELECT * FROM occurrences WHERE id=?", (occurrence_id,)).fetchone()
            if not track:
                raise KeyError("Unknown occurrence")
            db.execute(
                "INSERT INTO events VALUES (?,?,?,?,?)",
                (event_id, occurrence_id, seconds, int(completed), now()),
            )
            db.execute(
                "UPDATE occurrences SET listened=listened+?, completed=MAX(completed,?) WHERE id=?",
                (seconds, int(completed), occurrence_id),
            )
            total = track["listened"] + seconds
            # Short-track completion must include the whole song, not a seek to its end.
            eligible = total >= 30 or (
                completed and 0 < track["duration"] < 30 and total >= track["duration"] - 0.75
            )
            if eligible and track["video_id"]:
                self._schedule(db, occurrence_id, "history", None)
        return True

    def _schedule(self, db, occurrence_id, kind, value):
        db.execute(
            "INSERT OR IGNORE INTO submissions VALUES (?,?,?,?,?,?,?,?,?)",
            (
                str(uuid4()),
                occurrence_id,
                kind,
                value,
                "pending",
                "Awaiting submission",
                now(),
                now(),
                None,
            ),
        )

    def schedule_rating(self, occurrence_id, rating, event_id=None):
        if rating not in ("LIKE", "DISLIKE", "INDIFFERENT"):
            raise ValueError("Unsupported rating")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                "SELECT video_id FROM occurrences WHERE id=?", (occurrence_id,)
            ).fetchone()
            if not row or not row["video_id"]:
                raise ValueError("Occurrence needs a YouTube video ID")
            kind = "rating:" + event_id if event_id else "rating"
            old = db.execute(
                "SELECT value FROM submissions WHERE occurrence_id=? AND kind=?",
                (occurrence_id, kind),
            ).fetchone()
            if old and old["value"] != rating:
                raise ValueError("Rating event ID reused with a different value")
            self._schedule(db, occurrence_id, kind, rating)

    def lease(self, device_id, force=False, release=False):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM device_lease WHERE slot=1").fetchone()
            if release:
                db.execute("DELETE FROM device_lease WHERE slot=1 AND device_id=?", (device_id,))
                return True
            if row and row["expires"] > time.time() and row["device_id"] != device_id and not force:
                return False
            db.execute(
                "INSERT OR REPLACE INTO device_lease VALUES (1,?,?)", (device_id, time.time() + 25)
            )
        return True

    def owns_lease(self, device_id):
        with self.connect() as db:
            row = db.execute("SELECT * FROM device_lease WHERE slot=1").fetchone()
        return not row or row["expires"] <= time.time() or row["device_id"] == device_id

    def submissions(self):
        with self.connect() as db:
            return [
                dict(row)
                for row in db.execute(
                    "SELECT s.*, o.video_id FROM submissions s JOIN occurrences o "
                    "ON o.id=s.occurrence_id ORDER BY s.created"
                )
            ]

    def claim(self, submission_id, baseline=None):
        with self.connect() as db:
            return (
                db.execute(
                    "UPDATE submissions SET state='sending', updated=?, baseline=? "
                    "WHERE id=? AND state='pending'",
                    (now(), json.dumps(baseline), submission_id),
                ).rowcount
                == 1
            )

    def outcome(self, submission_id, state, detail):
        with self.connect() as db:
            db.execute(
                "UPDATE submissions SET state=?, detail=?, updated=? WHERE id=?",
                (state, detail, now(), submission_id),
            )

    def evidence(self, kind, status, details):
        with self.connect() as db:
            db.execute(
                "INSERT INTO evidence VALUES (?,?,?,?,?)",
                (str(uuid4()), kind, status, json.dumps(details), now()),
            )

    def report(self):
        with self.connect() as db:
            rows = [dict(row) for row in db.execute("SELECT * FROM evidence ORDER BY created")]
            totals = dict(
                db.execute(
                    "SELECT COUNT(*) occurrences, COALESCE(SUM(listened),0) "
                    "listened_seconds FROM occurrences"
                ).fetchone()
            )
            songs = [
                dict(row)
                for row in db.execute(
                    "SELECT tidal_id, title, artist, SUM(listened) listened_seconds FROM occurrences "
                    "GROUP BY tidal_id ORDER BY listened_seconds DESC LIMIT 20"
                )
            ]
            artists = [
                dict(row)
                for row in db.execute(
                    "SELECT artist, SUM(listened) listened_seconds FROM occurrences "
                    "GROUP BY artist ORDER BY listened_seconds DESC LIMIT 20"
                )
            ]
        for row in rows:
            row["details"] = json.loads(row["details"])
        latest = {row["kind"]: row for row in rows}
        required = (
            "song_radio",
            "personal_mix",
            "lossless_decode",
            "hires_decode",
            "lossless_playback",
            "hires_playback",
            "history_visibility",
        )
        missing = [kind for kind in required if latest.get(kind, {}).get("status") != "passed"]
        return {
            "phase": "integration_prototype",
            "gate": "blocked" if missing else "passed",
            "missing_evidence": missing,
            "recap": "unverified",
            "evidence": rows,
            "totals": totals,
            "top_songs": songs,
            "top_artists": artists,
            "submissions": self.submissions(),
        }

    def correction(self, video_id, tidal_id=None):
        with self.connect() as db:
            if tidal_id is not None:
                db.execute(
                    "INSERT OR REPLACE INTO corrections VALUES (?,?,?)", (video_id, tidal_id, now())
                )
            row = db.execute(
                "SELECT tidal_id FROM corrections WHERE video_id=?", (video_id,)
            ).fetchone()
        return row[0] if row else None

    def add_autoplay_page(self, cursor, state):
        with self.connect() as db:
            db.execute(
                "INSERT INTO autoplay_pages VALUES (?,?,?,NULL,?)",
                (cursor, state["session_id"], json.dumps(state), now()),
            )

    def autoplay_page(self, cursor):
        with self.connect() as db:
            row = db.execute(
                "SELECT state,response FROM autoplay_pages WHERE cursor=?", (cursor,)
            ).fetchone()
        if not row:
            raise KeyError("Unknown Autoplay cursor")
        return json.loads(row["state"]), json.loads(row["response"]) if row["response"] else None

    def finish_autoplay_page(self, cursor, response, next_cursor, state):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                "SELECT response FROM autoplay_pages WHERE cursor=?", (cursor,)
            ).fetchone()
            if not row:
                raise KeyError("Unknown Autoplay cursor")
            if row["response"] is not None:
                return json.loads(row["response"])
            if next_cursor:
                db.execute(
                    "INSERT INTO autoplay_pages VALUES (?,?,?,NULL,?)",
                    (next_cursor, state["session_id"], json.dumps(state), now()),
                )
            db.execute(
                "UPDATE autoplay_pages SET response=? WHERE cursor=?",
                (json.dumps(response), cursor),
            )
        return response
