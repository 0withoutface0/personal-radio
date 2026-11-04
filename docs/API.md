# Server interfaces

Base origin: `http://127.0.0.1:8765`. All `/api` endpoints require `Authorization: Bearer DEVICE_TOKEN`. Read the token locally from `data/device-token.txt`; provider cookies and Tidal tokens are never client credentials. The local diagnostic page has a separate HttpOnly cookie session with same-origin mutation protection.

The complete schemas are generated at authenticated `GET /api/openapi.json`. A credential-free snapshot is included in [openapi.json](openapi.json).

| Interface | Purpose |
| --- | --- |
| `GET /api/accounts` | Presence of credential files; not proof of current subscription or streaming access |
| `GET /api/search?q=…` | Signed-in YouTube song search |
| `GET /api/catalog/search?q=…&kind=songs/artists/albums` | Typed catalog search; returns `{kind, items}` (default songs) |
| `GET /api/catalog/artists/{id}` | Artist details, top songs, and release previews |
| `GET /api/catalog/artists/{id}/releases?kind=albums/singles&limit=100` | Artist releases in provider order; increase limit to load more |
| `GET /api/catalog/albums/{id}` | Album details and ordered track list, including unavailable tracks |
| `GET /api/stations` | Personalized RD playlists discovered on the signed-in home page |
| `POST /api/radio` | `{video_id}` or `{playlist_id}`, optional `limit`; returns ordered recommendations and station context |
| `POST /api/autoplay` | `{video_id, limit?}` starts normal-play Autoplay; `{cursor}` continues a saved queue |
| `POST /api/match` | YouTube recording metadata → confident Tidal recording or visible skipped reason/candidates |
| `PUT /api/corrections` | `{video_id, tidal_id}` saves a deliberate manual mapping |
| `POST /api/streams` | `{tidal_id}` → ephemeral stream UUID, local URL, and provider source metadata |
| `GET /api/streams/{uuid}/manifest.m3u8` | Proxy manifest with local relative segment URLs |
| `GET, HEAD /api/streams/{uuid}/assets/{index}.flac` | Direct FLAC asset; single byte Range supported |
| `GET, HEAD /api/streams/{uuid}/assets/{index}.m4s` | Initialization or audio segment for HLS |
| `POST /api/occurrences` | `{tidal_id, video_id?}` → new occurrence UUID; ID pairing is explicit prototype input |
| `GET /api/occurrences/{uuid}` | Durable local totals for resume/reconciliation |
| `POST /api/events` | `{id, occurrence_id, seconds, completed}`; unique event UUID, 0–5-second actual playback interval |
| `POST /api/ratings` | `{occurrence_id, value}`; `LIKE`, `DISLIKE`, or `INDIFFERENT` |
| `POST /api/reporting/flush` | Dispatch safely pending work, then read account state; uncertain mutations are never resent |
| `POST /api/reporting/reconcile` | Read account state without provider mutations |
| `POST /api/checks/decode` | `{tidal_id, expect_hires}`; starts one full-source decoder job, returns HTTP 202 and job UUID |
| `GET /api/checks/{uuid}` | In-memory decoder job status; durable results are also in the report |
| `POST /api/checks/playback` | mpv harness results linked to a prior successful decode and durable occurrence totals |
| `GET /api/report` | Evidence, integration gate, listening totals, top songs, and reporting states |

`POST /setup/youtube` accepts `{text: browser_headers}`; `POST /setup/tidal/start` begins local PKCE; `POST /setup/tidal/finish` accepts `{text: redirect_url}`. All setup endpoints are disabled with `RADIO_LOCAL_SETUP=0`.

Autoplay is distinct from explicit Start radio. Its first provider request omits `playlistId` and radio params, then follows the returned Automix endpoint. The first page includes the selected song. Responses contain `mode: "autoplay"`, `session_id`, `seed_video_id`, `playlist_id`, `tracks`, `has_more`, and `next_cursor`. Page size is fixed by the initial `limit` (default 25, range 1–100); omit `limit` on cursor requests. Exactly one of `video_id` and `cursor` is required.

Autoplay cursors are opaque server-generated UUIDs, not YouTube tokens. Provider params, continuations, buffered tracks, and cached page results stay in SQLite. Cursor retries return the identical response, including its next cursor. Start a new session only when the user deliberately selects another song or mode. After a server restart, a saved cursor resumes the same provider context; an expired upstream continuation fails visibly instead of resetting the radio. Metadata requests create no playback occurrences or listening events.

Playback events are intervals of measured audio time rather than wall-clock gaps between heartbeats. They must omit pauses, buffering, seek discontinuities, and application downtime. The client must persist a UUID and payload before sending, retain both until acknowledgement, and reuse both exactly on retry. Reusing an event UUID with a changed payload is an error.

A history submission is unique per occurrence, not per YouTube video. Distinct later occurrences may report the same video again. Event insertion, cumulative time, and history scheduling share one SQLite transaction. Source decoding produces no listening events.

Submission states: `pending`, `sending`, `submitted`, `visible`, `uncertain`. Startup recovery turns interrupted `sending` rows into `uncertain`. A `visible` result for a previously present history item does not independently pass the integration gate. The report retains that distinction. Responses never contain upstream signed media URLs or provider authentication data.

The Flutter clients use `POST /api/queues` for all three modes. Start with `{mode: "autoplay", video_id, limit?}`, `{mode: "radio", video_id, limit?}`, or `{mode: "station", playlist_id, limit?}`. Station IDs must come from the signed-in account. Continue any mode with `{cursor}` only. All responses preserve mode, session ID and provider order; the initial page size remains fixed. Cursor retries return the same page across restarts.

`POST /api/occurrences` additionally accepts a client-generated `id` UUID. Repeating it with the same YouTube/Tidal pair returns the same occurrence; changing the pair is rejected. The app persists this UUID before opening audio. `POST /api/ratings` additionally accepts an `id` UUID for an explicit action. Reuse it on retries; use a new ID for a deliberate change of rating.

Ratings also accept optional `tidal_favorite: true|false`. `LIKE` always schedules a YouTube rating and a Tidal favorite for the occurrence's matched `tidal_id`. New clients send `false` when clearing/changing a prior Like; this schedules removal from Tidal favorites alongside the YouTube action. Without explicit intent, legacy callers remove the Tidal favorite only when replacing a previous app Like. A standalone dislike is YouTube-only. Favoriting Tidal with a non-Like rating is rejected.

Both targets are inserted in one SQLite transaction and deduplicate against the same client action ID: `rating:UUID` for YouTube and `tidal_favorite:UUID` for Tidal. Report rows include `provider` (`youtube` or `tidal`) and `tidal_id`. Each target is dispatched and reconciled independently. New explicit choices mark older unsent work for that provider/target `superseded`; ambiguous or in-flight writes are retained and never blindly retried. Existing historical YouTube rating rows are not backfilled into Tidal favorites.

`POST /api/device/lease` takes `{device_id, force?: false, release?: false}`. An active lease lasts 25 seconds; players renew every six seconds while playing/buffering. Stream creation checks `X-Device-ID` against the active lease and returns 409 if another device owns it. A forced takeover causes the previous client to pause at its next heartbeat. Asset requests still require the bearer token. The clients persist real listening events even if a newer device has taken over.

`GET /api/streams/{uuid}/quality` inspects the proxied source using ffprobe and returns `verified`, `codec`, `bit_depth`, `sample_rate`, and `source_quality`. A failed probe returns `verified: false`; clients must not display provider resolution as measured resolution. The probe does not decode or transcode audio for playback. Set `RADIO_INTERNAL_ORIGIN` when the internal API origin differs from loopback port 8765.

`POST /api/reporting/dispatch` schedules a serialized background flush and returns 202 immediately. It never retries ambiguous provider mutations. `GET /api/report` also includes `top_artists` (grouped by stored artist credit) alongside durable totals and top songs.

`POST /api/match` accepts optional `video_type` and `counterpart` audio metadata (the same recording fields, without recursive counterparts). Queues retain these fields when YouTube supplies them. Old video entries without album/type metadata are refreshed by their original video ID. A linked audio counterpart takes priority; otherwise official-song search requires matching normalized title, complete artist credits, recording version and compatible video runtime. Tidal duration checks remain within two seconds of the audio reference. Known explicit/clean and ISRC conflicts still reject a match. Saved manual corrections take priority.

Resolved responses include `method: "youtube_counterpart"` or `"youtube_song_metadata"` and `audio_source` for diagnostic provenance. This does not replace the original queue video ID, station context or occurrence ID used for reporting. Ambiguous responses retain ranked candidates and their individual rejection reasons; matching requests themselves create no listening activity.

Outside loopback, disable local account setup with `RADIO_LOCAL_SETUP=0`, whitelist the service hostname/IP with `RADIO_ALLOWED_HOSTS`, and expose the private listener through Tailscale. The Windows CLI `serve --host 100.x.x.x` performs those binding/setup restrictions for the PC's Tailscale address. Provider credentials and opaque provider continuation parameters remain server-side.

Catalog routing uses signed-in YouTube Music for songs, artists and albums. Tidal remains the recording matcher and lossless audio provider. Catalog songs retain their original `video_id` for history and dual-service ratings, plus `artist_refs: [{id, name}]` and `album_id` for browsing. Artist and album IDs are YouTube browse IDs, not Tidal IDs or subscription channel IDs. Catalog reads never create occurrences, listening events or ratings. Unavailable album tracks remain visible with `available: false`; they must not be played. Album tracks inherit missing artist credits and artwork from their album; explicit status stays track-specific.

Artist release requests keep shelf parameters on the server. `kind` accepts `albums` or `singles`; `limit` is 1–1000. Responses contain `items`, `limit`, `has_more`, and `limited`. Load more by increasing the limit and replacing the displayed list (the provider library has no offset interface). A full page can conservatively report `has_more` until a larger read proves exhaustion. At 1000 releases, `limited: true` explicitly indicates the cap. Search returns up to 30 results. The older song-only `/api/search` remains compatible.

The player owns its editable queue and persists it on the device, alongside the existing event outbox. A direct catalog Play replaces that queue with `mode: queue` and no recommendation cursor; it uses the same matching, occurrence, stream and reporting interfaces. Add to queue appends to the current list; Play next inserts after the current index. Albums keep track order. Insertions preserve the radio mode, cursor, current occurrence, position and pending events; they do not call a provider activity interface. Future recommendation pages append after the current list. Each addition gets a fresh persisted occurrence UUID; existing entries retain theirs. Queue edits do not transfer between devices.
