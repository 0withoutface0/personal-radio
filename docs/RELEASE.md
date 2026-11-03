# Early release acceptance

Delivered implementation: one Flutter codebase for Windows and Android; separate Autoplay, explicit radio and personalized-station modes; lossless media_kit playback; Android audio_service/audio_session integration; durable queue/outbox state; server-side matching/corrections, source-quality verification, device leases and best-effort activity reporting. Release binaries and SHA-256 checksums are under `dist/`. Setup and reproducible build commands are in `player/README.md`.

Remaining acceptance work:

1. Install on a physical Android device and check screen lock, notification/headset controls, unplug, audio focus, calls/interruptions and battery restrictions.
2. Listen through a full Hi-Res recording on Windows and Android. Full account-backed 24-bit source decoding has passed; device playback is a distinct check.
3. Exercise prolonged playback across recommendation batches on both native targets, plus real network loss, server restart and device takeover during playback. Server pagination and Windows natural advancement have passed separately.
4. Verify an intentional dislike and rating clearing in the account; a user has confirmed a like reached YouTube. A submitted history song is visible, but attribution to that specific occurrence remains uncertain because it was already present. Keep Recap unverified.
5. Deploy to a Linux server, configure private Tailscale access, and test the phone's connection. The Docker image and isolated persistence smoke test pass; remote deployment acceptance remains open.

One active playback lease is enforced; the prior device pauses on its next six-second heartbeat after takeover. Provider credentials remain on the server. Keep the private Android release keystore/properties backed up for future sideload updates. Do not put account files, device tokens or signing secrets in distributed app packages.

Offline downloads, synchronized multiroom, Android Auto, exclusive audio output and guaranteed bit-perfect hardware playback remain outside this release.
