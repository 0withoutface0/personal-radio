# YouTube Music renewal on OMV

The Android app can use a dedicated browser on OMV to renew its YouTube Music session. Tidal playback and the listening database run on the phone in standalone mode. YouTube Music's library signs each request with the current time. Renewal supplies the browser session cookies when YouTube stops accepting the saved session.

## Start the service

From the repository root on OMV, run:

```sh
docker compose -p personal-radio-auth -f auth-server/compose.yaml up -d --build
tailscale serve --bg --https=8443 http://127.0.0.1:8770
```

If Tailscale runs in a host-network Docker container, run the second command using `docker exec YOUR_TAILSCALE_CONTAINER tailscale serve ...`. Use the address printed by Serve. Leave Funnel off.

The browser profile and both service secrets are stored in the `personal-radio-auth_youtube-browser` Docker volume. Keep the browser console bound to loopback. The device token grants access to transferable YouTube Music session credentials. Keep it private and use this service only on your own tailnet.

## Sign in from your computer

Connect to the local browser console through an SSH account authorized to forward only the required destination.

```sh
ssh -N -L 127.0.0.1:18771:127.0.0.1:8771 USER@OMV
```

Open [the forwarded console](http://127.0.0.1:18771/vnc.html?autoconnect=1&resize=scale), then enter the console password from a separate private SSH terminal. Run the command on OMV.

```sh
docker compose -p personal-radio-auth -f auth-server/compose.yaml exec -T youtube-auth cat /state/vnc.password
```

Sign into YouTube Music in the dedicated Chromium window. Close the console and tunnel after you verify the correct channel is selected. If Google asks for a security check, complete it directly in that browser. Sign in there again if Google invalidates the browser session or if Chromium loses the sign-in after a container restart.

## Connect the phone

1. Keep Tailscale connected. In Personal Radio open **Settings â†’ On this device â†’ YouTube Music â†’ Set up server renewal**.
2. Enter the Serve HTTPS address and paste the value from the command below. Use the same channel already connected to the phone to preserve the account association for queued reports.
3. Tap **Connect**. The settings screen shows the server when renewal is enabled. **Check accounts** tests the saved session and requests fresh credentials if needed. **Turn off server renewal** removes the server token while retaining the last valid session.

```sh
docker compose -p personal-radio-auth -f auth-server/compose.yaml exec -T youtube-auth cat /state/device-token.txt
```

Use `GET /health` to check service reachability. `POST /v1/session` requires the renewal token in an Authorization bearer header and returns sensitive session data. The app verifies the channel again before storing the response in its encrypted vault. Failed YouTube reads can retry once after renewal. Pending reports stay tied to their original channel and uncertain writes are never automatically replayed.
