# Early release acceptance

Delivered implementation (v0.3.1): one Flutter codebase for Windows and Android; personalized Speed dial and Quick picks; song/artist/album catalog browsing, finite direct playback queues, Add to queue and Play next; separate Autoplay, explicit radio and personalized-station modes; lossless media_kit playback; Android audio_service/audio_session integration; durable queue/outbox state; server-side matching/corrections, source-quality verification, device leases and best-effort activity reporting. Release binaries and SHA-256 checksums are under `dist/`. Setup and reproducible build commands are in `player/README.md`.

Remaining acceptance work:

1. Install on a physical Android device and check screen lock, notification/headset controls, unplug, audio focus, calls/interruptions and battery restrictions.
2. Listen through a full Hi-Res recording on Windows and Android. Full account-backed 24-bit source decoding has passed; device playback is a distinct check.
3. Exercise prolonged playback across recommendation batches on both native targets, plus real network loss, server restart and device takeover during playback. Server pagination and Windows natural advancement have passed separately.
4. Verify an intentional dislike and rating clearing in the account; a user has confirmed a like reached YouTube. A submitted history song is visible, but attribution to that specific occurrence remains uncertain because it was already present. Keep Recap unverified.
5. Deploy to a Linux server and test that deployment's phone connection. Private HTTPS Tailscale access to the Windows-hosted server is configured, and the user reports Android screen-off playback. The Docker image and isolated persistence smoke test pass; remote Linux deployment acceptance remains open.

One active playback lease is enforced; the prior device pauses on its next six-second heartbeat after takeover. Provider credentials remain on the server. Keep the private Android release keystore/properties backed up for future sideload updates. Do not put account files, device tokens or signing secrets in distributed app packages.

Offline downloads, synchronized multiroom, Android Auto, exclusive audio output and guaranteed bit-perfect hardware playback remain outside this release.

Catalog and home shelf reads were checked against the signed-in YouTube account. Playback and queue editing use the same lossless stream and durable reporting paths as radio; new feature tests use fake transport/providers and create no real listening or rating activity. Install the matching server revision before the v0.3.0 clients (home API version 0.4.0). Existing client queue/outbox state and server SQLite records remain compatible.

Version 0.3.0 opens Discover on For you with a paged three-by-three Speed dial grid and Quick picks song columns. Song and playlist shortcuts preserve YouTube's returned playback targets, including Play all; artist and album shortcuts browse their catalog pages. Refreshing recommendations preserves the active queue and pending events. Missing shelves and expired authentication are shown visibly. A local account reconnection now reloads the server's cached YouTube client automatically. Home selection IDs expire after a server restart or timeout; refresh Home to retrieve new ones.

This release retains v0.2.3's occurrence-specific queue removal (button, menu or right-to-left swipe), ended-queue preservation, and Android notification icon resource protections. Removing a song never completes or dislikes it. Packaging checks media control icons in the compiled APK.

Version 0.3.1 improves recovery after temporary network interruptions. API deadlines include response bodies, heartbeat failures preserve audio only inside the confirmed lease window, and stalled streams reopen with bounded retries at the same occurrence and position. Pause and track changes cancel late playback. Native memory buffering targets 90 seconds within 96 MiB. No Python server migration is needed from v0.3.0. Offline tests and a generated-audio native network test pass; physical cellular acceptance and the root cause of phone-wide Tailscale failures remain separate checks. See [network troubleshooting](NETWORK.md).
