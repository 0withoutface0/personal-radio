# Verification status

Version 0.1.1 is an early release. The Windows executable, signed Android APK and Linux Docker image have been built. Physical Android acceptance checks and continuous full Hi-Res playback on each device remain open. Recap inclusion is unverified.

Automated checks: **81 Python tests**, **14 Flutter unit/widget tests**, clean Ruff checks and clean Flutter analysis. Tests use temporary state and provider fixtures. Decoder tests generate their own audio; they do not certify account access or audible device playback.

| Check | Evidence / status |
| --- | --- |
| Authenticated Autoplay | Three consecutive saved pages retrieved; cursor retries stable |
| Authenticated explicit radio | Three saved pages; mode and session preserved |
| Personalized stations | Discovered from the signed-in account; station pagination checked |
| Recording matching | Studio/live/remix/explicit/conflict fixtures pass; live catalog matching checked |
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
| Official Recap inclusion | Unverified independently of successful history submission |
| Windows release | Release executable and complete DLL/assets bundle built |
| Android release | Signed universal APK; API 24 minimum, API 36 target; ARM64, ARMv7 and x86_64 |
| Android screen-off/notification/headset/interruptions | Implemented; physical-device verification pending |
| Continuous full Hi-Res playback on each device | Pending |
| Docker | Image built; isolated read-only/non-root container passed auth, setup isolation and restart persistence checks |
| Remote Linux / Tailscale phone deployment | Instructions supplied; deployment acceptance pending |

The machine-readable prototype gate has stricter evidence requirements, including distinct full-playback and newly-visible-history checks. A built app does not satisfy every gate. Source decoding does not establish that a person heard a full recording, and source resolution does not establish bit-perfect hardware output.

To repeat the opt-in native playback test, follow the [player guide](../player/README.md). Add `--dart-define=RADIO_FULL_TRACK=true` for the slower natural-end test. This test plays real audio and can report actual listening. Ordinary offline tests never use provider accounts.

Account-specific reports, tokens, listening records and signing material are private local state and are excluded from the repository and application packages.
