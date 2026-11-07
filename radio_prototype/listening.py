from collections import defaultdict

FIRST_INSTANT = "0001-01-01T00:00:00+00:00"
RANK_LIMIT = 12


def listening_stats(store, boundaries, *, all_time=False):
    """Aggregate saved playback intervals in the device's calendar buckets."""
    start = FIRST_INSTANT if all_time else boundaries[0]
    # Include older listening even if it predates the visible monthly buckets.
    edges = [start, *boundaries] if start < boundaries[0] else boundaries
    intervals = list(zip(edges, edges[1:]))
    placeholders = ", ".join("(?, ?, ?)" for _ in intervals)
    parameters = [item for i, (left, right) in enumerate(intervals) for item in (i, left, right)]
    with store.connect() as db:
        # Keep totals, chart and ranks on the same read snapshot during sync.
        db.execute("BEGIN")
        first = db.execute(
            "SELECT COALESCE(played_at, created) FROM events WHERE seconds > 0 "
            "ORDER BY COALESCE(played_at, created) LIMIT 1"
        ).fetchone()
        buckets = [
            {
                "start": None if row["start"] == FIRST_INSTANT else row["start"],
                "end": row["end"],
                "listened_seconds": row["listened_seconds"],
            }
            for row in db.execute(
                f"""
                WITH buckets(idx, start, end) AS (VALUES {placeholders})
                SELECT b.start, b.end, COALESCE(SUM(e.seconds), 0) listened_seconds
                FROM buckets b LEFT JOIN events e
                  ON e.seconds > 0 AND COALESCE(e.played_at, e.created) >= b.start
                  AND COALESCE(e.played_at, e.created) < b.end
                GROUP BY b.idx ORDER BY b.idx
                """,
                parameters,
            )
            if row["start"] != FIRST_INSTANT or row["listened_seconds"] > 0
        ]
        songs = [
            dict(row)
            for row in db.execute(
                """
                WITH heard AS (
                    SELECT occurrence_id, SUM(seconds) listened_seconds
                    FROM events
                    WHERE seconds > 0 AND COALESCE(played_at, created) >= ?
                      AND COALESCE(played_at, created) < ?
                    GROUP BY occurrence_id
                ), choices AS (
                    SELECT o.tidal_id, s.value,
                      ROW_NUMBER() OVER (
                        PARTITION BY o.tidal_id ORDER BY s.created DESC, s.rowid DESC
                      ) latest
                    FROM submissions s JOIN occurrences o ON o.id = s.occurrence_id
                    WHERE s.kind = 'rating' OR s.kind LIKE 'rating:%'
                )
                SELECT o.tidal_id, MAX(o.title) title, MAX(o.artist) artist,
                       SUM(h.listened_seconds) listened_seconds, COUNT(*) plays,
                       COALESCE(MAX(c.value = 'LIKE'), 0) liked
                FROM heard h JOIN occurrences o ON o.id = h.occurrence_id
                LEFT JOIN choices c ON c.tidal_id = o.tidal_id AND c.latest = 1
                GROUP BY o.tidal_id
                ORDER BY listened_seconds DESC, o.tidal_id
                """,
                (start, boundaries[-1]),
            )
        ]
    artist_totals = defaultdict(lambda: {"listened_seconds": 0, "plays": 0})
    for song in songs:
        song["liked"] = bool(song["liked"])
        artist = artist_totals[song["artist"]]
        artist["listened_seconds"] += song["listened_seconds"]
        artist["plays"] += song["plays"]
    artists = [{"artist": name, **totals} for name, totals in artist_totals.items()]
    artists.sort(key=lambda row: (-row["listened_seconds"], row["artist"]))
    most_played = sorted(songs, key=lambda row: -row["plays"])
    return {
        "first_played_at": first[0] if first else None,
        "totals": {
            "listened_seconds": sum(song["listened_seconds"] for song in songs),
            "plays": sum(song["plays"] for song in songs),
            "songs": len(songs),
            "artists": len(artists),
        },
        "buckets": buckets,
        "top_songs": songs[:RANK_LIMIT],
        "most_played": most_played[:RANK_LIMIT],
        "liked_songs": [song for song in songs if song["liked"]][:RANK_LIMIT],
        "top_artists": artists[:RANK_LIMIT],
    }
