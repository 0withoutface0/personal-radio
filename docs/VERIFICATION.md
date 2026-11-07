# Verification status

Version 0.5.0 is an early release. The Windows executable, signed Android APK and Linux Docker image are distributed separately from private account state. Physical Android acceptance checks and continuous full Hi-Res playback on each device remain open. Recap inclusion is unverified.

Automated checks: **155 Python tests** (server API 0.5.0), **109 Flutter unit/widget tests** (v0.5.0 player), clean Ruff checks and clean Flutter analysis. Tests use temporary state and provider fixtures. Decoder tests generate their own audio; they do not certify account access or audible device playback.

| Check | Evidence / status |
| --- | --- |
| Listening dashboard | Protected date-range API, legacy database migration, daylight saving boundaries, deduplication, delayed offline events and favorite ranks checked. Phone and Windows widget layouts cover chart taps, date navigation and out-of-order responses. |
| Material You / themes | Defaults, OS brightness, resume refresh, preset persistence and phone/Windows layouts pass widget tests; Android 16 native Monet palette and Original green selection verified with the real dynamic-color plugin |
| Android media Like | Native foreground service active and MediaSession exposes Remove like after the fixture Like; actual dual-service requests mocked. Unit tests verify clear, offline persistence and stale/duplicate delivery. Physical OEM action visibility remains an acceptance check |
| Prepared next-track handoff | Native Windows generated PCM and 24-bit/96kHz FLAC HLS tests fetch authenticated next audio before EOF, advance through the native playlist without another stream resolution, and preserve occurrence registration order. The same PCM and Hi-Res HLS checks pass on the Android 16 emulator |
| Preload cancellation | Queue insertion/removal, late responses, skips, pause, seek, uncertain matches and durable registration/ratings ordering covered by fake-transport tests. Native prefetch errors leave healthy current audio alone; expired leases block handoff |
| Partial counterpart metadata | Empty or omitted artists on YouTube's optional counterpart accepted without weakening primary artist, explicit/clean or size constraints. Live read-only verification matched the reported Speed dial and search song to the same Tidal recording; no playback events or ratings created |
| Cellular outage recovery | Fake transport covers stalled headers/body, aborted requests without automatic mutation replay, serialized heartbeats, bounded lease grace, takeover, retries, saved occurrences/position and pause/skip cancellation |
| Native network buffering | Windows native integration check passed with generated silence and a deliberately stalled loopback HTTP socket; confirmed memory cache settings and advancing playback during the stall; no accounts or activity reporting used |
| Phone-wide VPN failures | A user reported intermittent cellular failures in other apps and audio remaining stalled after internet access recovered. Direct cellular connectivity was observed, with substantial latency variation. The underlying Android/Tailscale cause and the new app's physical cellular recovery remain unverified |
| Personalized home shelves | Live read-only verification retrieved 19 Speed dial shortcuts (songs, artists, albums and playlists), 20 Quick picks and the provider's Play all action after account reconnection |
| Home playback context | Speed dial song/playlist, Quick pick and Play all returned ordered initial and subsequent pages in an isolated SQLite store; no listening or rating writes |
| Home UI and refresh | Phone/desktop layout, touch and button paging, artist/album navigation, exact playback targets, long-press queue action, search return, errors and stale refreshes covered; refresh leaves queue/outbox untouched |
| Credential reconnection | Updated browser-auth files invalidate cached YouTube clients and home feeds; expired account feeds fail visibly instead of presenting anonymous recommendations as personal |
| Catalog search and browsing | Live read-only song/artist/album search, artist releases and album tracks retrieved; no listening or rating writes |
| Song context menus | Windows right-click and touch long-press across song views, cancellation, unavailable tracks, pointer positioning and radio-state preservation covered with fake transport |
| Catalog player | Phone/desktop widget tests cover artist releases, album navigation, selected-track playback, now-playing links and Ctrl+K |
| Queue editing | All three radio modes retain cursor, order, position, occurrence IDs and pending events across insertion/removal/restoration; duplicate occurrences, current-track removal, right-to-left swipe and in-flight pagination covered |
| Direct queue and replay | Finite queues, fresh replay occurrences, unavailable tracks, stale searches/pages and corrected stream identity covered with fake transport |
| Authenticated Autoplay | Three consecutive saved pages retrieved; cursor retries stable |
| Authenticated explicit radio | Three saved pages; mode and session preserved |
| Personalized stations | Discovered from the signed-in account; station pagination checked |
| Recording matching | Studio/live/remix/explicit/conflict fixtures pass; live catalog matching checked |
| Music-video matching | Linked audio counterparts preserved; official-song metadata resolves video-runtime differences; live checks recovered seven previously skipped recordings and retained one ambiguous result for manual choice |
| Full standard FLAC source | 16-bit / 44.1 kHz full decode and native Windows playback verified |
| Full Hi-Res FLAC source | Full 24-bit / 44.1 kHz source decoded; device playback is a separate check |
| Server lossy conversion | None; original FLAC assets and manifest proxy |
| Windows automatic advancement | Observed at natural end of a full song |
| Windows pause/seek/skip/restart | Opt-in native integration test passed; occurrence and saved position retained |
| Durable retries and ambiguous provider writes | Automated tests; stable event UUIDs, uncertain writes never blindly resent |
| History submission | Request acknowledged and song visible in account history |
| Attribution of that specific history occurrence | Unverified because the song was already present before submission |
| Explicit ratings | API/idempotency fixtures pass; a user confirmed a like reached YouTube; live dislike/clear verification remains open |
| Rating feedback | Selected buttons, clearing, restart persistence, offline retries and outcome labels covered by Flutter tests |
| Likes on both providers | Mocked writes cover independent outcomes, offline accounts, restart/idempotency, clearing and superseded choices; live Tidal favorites read verified; new live account writes were not created for tests |
| Official Recap inclusion | Unverified independently of successful history submission |
| Windows release | Release executable and complete DLL/assets bundle built |
| Android release | Signed universal APK; API 24 minimum, API 36 target; ARM64, ARMv7 and x86_64 |
| Android screen-off/notification/headset/interruptions | User reports screen-off playback on Redmi; fixed release media session/notification, screen-off retention and system media commands (pause/play/stop) verified on Android 16 emulator with generated audio and an isolated fixture server. Physical notification/headset/interruption confirmation remains open. |
| Continuous full Hi-Res playback on each device | Pending |
| Docker | Image built; isolated read-only/non-root container passed auth, setup isolation and restart persistence checks |
| Windows-hosted Tailscale phone access | Private HTTPS proxy configured with verified certificate; authenticated/unauthenticated API, host restriction and disabled setup checked; TCP fallback also verified; APK and approved connection file sent to own phone; user reports Android playback continuing with screen locked |
| Remote Linux deployment | Instructions supplied; deployment acceptance pending |

The machine-readable prototype gate has stricter evidence requirements, including distinct full-playback and newly-visible-history checks. A built app does not satisfy every gate. Source decoding does not establish that a person heard a full recording, and source resolution does not establish bit-perfect hardware output.

To repeat the opt-in native playback test, follow the [player guide](../player/README.md). Add `--dart-define=RADIO_FULL_TRACK=true` for the slower natural-end test. This test plays real audio and can report actual listening. Ordinary offline tests never use provider accounts.

Account-specific reports, tokens, listening records and signing material are private local state and are excluded from the repository and application packages.

The API 0.4.1 counterpart patch was tested and loaded in the native Windows-hosted server. A Docker rebuild could not run for this patch because the local Docker engine was stopped; the earlier image/persistence evidence above predates this patch.
