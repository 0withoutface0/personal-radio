"""Versioned listening data without credentials or provider submission state."""

from datetime import UTC
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import AwareDatetime, BaseModel, Field


class HistoryTrack(BaseModel):
    tidal_id: int = Field(gt=0)
    title: str = Field(max_length=1000)
    artist: str = Field(max_length=1000)
    duration: float = Field(ge=0, allow_inf_nan=False)
    created: AwareDatetime


class HistoryEvent(BaseModel):
    id: UUID
    occurrence_id: UUID
    played_at: AwareDatetime
    seconds: float = Field(ge=0, le=5, allow_inf_nan=False)
    completed: bool


class Archive(BaseModel):
    version: int = Field(ge=1, le=1)
    tracks: dict[UUID, HistoryTrack] = Field(max_length=200_000)
    events: list[HistoryEvent] = Field(max_length=500_000)


def export_page(store, after, through, local_only):
    with store.connect() as db:
        db.execute("BEGIN")
        if through is None:
            through = db.execute("SELECT COALESCE(MAX(rowid),0) FROM events").fetchone()[0]
        rows = db.execute(
            """
            SELECT e.rowid seq, e.id, e.occurrence_id, COALESCE(e.played_at,e.created) played_at,
                   e.seconds, e.completed, o.tidal_id, o.title, o.artist, o.duration,
                   o.created
            FROM events e JOIN occurrences o ON o.id=e.occurrence_id
            WHERE e.rowid > ? AND e.rowid <= ? AND (e.seconds > 0 OR e.completed)
              AND (NOT ? OR o.id NOT IN (SELECT occurrence_id FROM imported_occurrences))
            ORDER BY e.rowid LIMIT 1500
            """,
            (after, through, local_only),
        ).fetchall()
    tracks = {
        row["occurrence_id"]: {
            key: row[key] for key in ("tidal_id", "title", "artist", "duration", "created")
        }
        for row in rows
    }
    events = [
        {key: row[key] for key in ("id", "occurrence_id", "played_at", "seconds")}
        | {"completed": bool(row["completed"])}
        for row in rows
    ]
    next_offset = rows[-1]["seq"] if len(rows) == 1500 else through
    return {
        "archive": {"version": 1, "tracks": tracks, "events": events},
        "after": next_offset,
        "through": through,
    }


def merge_archive(store, archive):
    inserted = 0
    with store.connect() as db:
        db.execute("BEGIN IMMEDIATE")
        for uid, track in archive.tracks.items():
            ident = str(uid)
            values = (
                track.tidal_id,
                track.title,
                track.artist,
                track.duration,
                track.created.astimezone(UTC).isoformat(),
            )
            old = db.execute(
                "SELECT tidal_id,title,artist,duration,created FROM occurrences WHERE id=?",
                (ident,),
            ).fetchone()
            if old is None:
                db.execute(
                    "INSERT INTO occurrences VALUES (?,NULL,?,?,?,?,0,0,?)", (ident, *values)
                )
                db.execute("INSERT INTO imported_occurrences VALUES (?)", (ident,))
            elif tuple(old) != values:
                raise ValueError("History contains a conflicting occurrence ID")
        for event in archive.events:
            if event.occurrence_id not in archive.tracks:
                raise ValueError("History event lacks track information")
            occurrence = str(event.occurrence_id)
            timestamp = event.played_at.astimezone(UTC).isoformat()
            old = db.execute(
                "SELECT occurrence_id,seconds,completed,COALESCE(played_at,created) "
                "FROM events WHERE id=?",
                (str(event.id),),
            ).fetchone()
            values = (occurrence, event.seconds, int(event.completed), timestamp)
            if old is not None:
                if tuple(old) != values:
                    raise ValueError("History contains a conflicting event ID")
                continue
            # This transaction never calls Store.event or schedules provider submissions.
            db.execute(
                "INSERT INTO events VALUES (?,?,?,?,?,?)",
                (str(event.id), *values, timestamp),
            )
            db.execute(
                "UPDATE occurrences SET listened=listened+?, completed=MAX(completed,?) WHERE id=?",
                (event.seconds, int(event.completed), occurrence),
            )
            inserted += 1
    return inserted


def history_routes(store, authorize):
    router = APIRouter(dependencies=[Depends(authorize)])

    @router.get("/api/local/history")
    def export(
        after: int = Query(0, ge=0),
        through: int | None = Query(None, ge=0),
        local_only: bool = False,
    ):
        return export_page(store, after, through, local_only)

    @router.post("/api/local/history")
    def import_history(archive: Archive):
        return {"inserted": merge_archive(store, archive)}

    return router
