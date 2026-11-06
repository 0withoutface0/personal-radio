# Cellular and Tailscale troubleshooting

A cellular speed test does not measure the private path to your server. Check that path while the fault is occurring:

```powershell
tailscale ping --c=10 --until-direct=false PHONE_TAILSCALE_IP
tailscale netcheck
tailscale version
```

Direct connections generally perform best; DERP relays add latency and can limit throughput. A healthy ping does not prove DNS or an existing audio connection is healthy. See [Tailscale's performance guide](https://tailscale.com/docs/reference/troubleshooting/poor-performance-tailnet).

If other phone apps also fail only while Tailscale is enabled:

1. Check the phone's selected exit node. Personal Radio only needs access to the server; an exit node is optional.
2. Compare a fresh hostname-based page with an IP-based page during the failure. Success by IP with hostname failures suggests DNS; both succeeding after recovery does not rule out an earlier intermittent fault.
3. Record the Tailscale version and Android Private DNS setting. Test one setting at a time. Turning off Use Tailscale DNS can break private hostname resolution, including a radio server addressed by its tailnet name.
4. Update both endpoints to current stable Tailscale. Version 1.104.5 specifically fixes Serve connectivity stalls on lossy networks, according to the [official changelog](https://tailscale.com/changelog#2026-11-02). That does not establish the cause of every Android internet failure.
5. As a workaround, use Android [app-based split tunneling](https://tailscale.com/docs/features/client/android-app-split-tunneling): avatar → App-based split tunneling → check affected apps to exclude them. Keep Personal Radio and any apps that require your private services included. Excluded apps bypass Tailscale routing and DNS.

Preserve a phone bug report from the failing state if the issue persists, then review it before sharing with Tailscale support. Do not publish account credentials, device tokens, private server logs or diagnostic screenshots in a project issue.

If internet access has recovered but only the song remains stalled, use the v0.3.1 player's automatic reconnect or press Pause then Play. The new player detects missing progress after 12 seconds and makes up to three attempts to reopen the same occurrence at its saved position. Buffered playback cannot continue indefinitely without a renewed device lease or new audio data. No app change can guarantee continuous playback through an extended VPN outage.
