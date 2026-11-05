# Personal Radio apps

One Flutter application targets Windows x64 and Android 7.0+ (API 24). Discover offers separate **Songs**, **Artists** and **Albums** searches. The play button plays a song directly without creating radio. Artist pages show top songs, albums and singles/EPs; album pages show the ordered track list, **Play album**, and playback starting at a selected track. Song actions also offer **Autoplay** and **Start radio / mix**. Stations uses the personalized mixes discovered from your account.

Queue removal targets a single occurrence, so other copies of the song stay in place. Use the row's **Remove from queue** button, its right-click/long-press menu, or swipe the row from right to left. Removing the current song skips to the next available song (or stops if the queue ends); it never sends a dislike or a completion. Removing other rows leaves playback and station context intact. Saved listening events remain in the outbox even after their queue row is removed.

Browsing uses your YouTube Music catalog. Song actions include **View artist** and **View album** where those links are supplied; album artist names open their pages. All songs still pass through the conservative Tidal matcher and original lossless stream proxy. Unavailable or uncertain recordings remain visible in Queue. Direct playback creates a finite queue; it does not enable recommendations automatically. A deliberate new Play creates new occurrence IDs while resuming the current occurrence keeps its saved ID.

## Run

Right-click a song in search results, artist pages, album tracks, Queue, now playing or the bottom player bar to open its song options at the pointer. Touch users can long-press. The menu offers Play next, Add to queue, Autoplay, Start radio / mix, and the artist/album links supplied with that song. Opening or dismissing the menu leaves playback and the queue untouched. The existing overflow buttons use the same actions.

Version **0.3.0 requires the matching updated server (API 0.4.0)** for Speed dial and Quick picks. Saved queues, outboxes and account records remain compatible with v0.2.x.

The **Now playing options** menu includes song actions and opens the linked album or credited artists. **Ctrl+K** returns to catalog search from any page. Starting a search or opening a catalog page dismisses the phone keyboard.

Resuming a paused track keeps its occurrence ID and saved position. Replaying a completed or previous track creates a fresh occurrence and starts at zero; any pending events for the older occurrence remain queued. Adding songs after a queue finishes leaves playback stopped; pressing Play then advances to the new songs.

**Play next** inserts immediately after the current song. Choosing Play next again puts the new selection first. **Add to queue** appends after all currently loaded tracks, before recommendation batches fetched later. Album actions insert the complete track list in album order. Neither action starts playback or changes your current radio/Autoplay station, cursor, position, or pending listening events. Queue marks these tracks **Added by you**. Each addition has a new occurrence ID, including repeated additions of the same song. An empty queue stays stopped until you select **Play queue** or a track's play button.

Configure the server first using the [root setup guide](../README.md). The player does not include account credentials or an embedded server.

Update the server from the same release before updating the player. Restart the Python service after updating source, or rebuild/recreate the Docker service with `docker compose up -d --build`. Keep its persistent data directory/volume. Install the new APK over the previous APK without uninstalling to retain the device queue/outbox; the release uses the same signing key. Close Windows Personal Radio before replacing its bundle, then restart it. Existing account sessions, matching corrections, ratings, queues and listening events do not require migration.

For a local source checkout with the Python environment and Windows release already prepared, double-click `Start Personal Radio.cmd` at the repository root. It starts the local Python service if necessary and opens the Windows release. Account files remain in `data/`. The launcher pairs the app using the device token; Flutter stores it using platform secure storage.

For a standalone Windows install, download `PersonalRadio-Windows-x64.zip` from [Releases](https://github.com/0withoutface0/youtube-tidal-radio/releases), unzip it and run `personal_radio.exe`. Keep its DLLs, notices and asset `data` folder beside it. This asset folder is different from the server's private `data/`. In Connection settings, enter your private server origin and the contents of the server's `data/device-token.txt`. The app requires the Microsoft Visual C++ 2015-2022 x64 runtime; install Microsoft's redistributable if it is missing.

Download `PersonalRadio-Android.apk` from Releases, copy it to your phone, allow installation from the app you use to open it, and install. Connect Tailscale on the phone. In Connection settings, enter `http://YOUR_PC_TAILSCALE_IP:8765` or your private HTTPS origin, plus the device token. `localhost` on Android means the phone, not the server. The Android emulator can use `http://10.0.2.3:8765` with that host added to `RADIO_ALLOWED_HOSTS` on the server. Provider cookies and Tidal session tokens belong only on the server.

For phone access while keeping the Windows launcher on loopback, use [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve). Create the private, Git-ignored `data/server-settings.json` with your PC's actual Tailscale IP and DNS name:

```json
{"local_setup": false, "allowed_hosts": ["100.x.x.x", "YOUR_PC.YOUR_TAILNET.ts.net"]}
```

Restart the Python service to load it, then run `tailscale serve --bg --tcp=8765 tcp://127.0.0.1:8765`. TCP forwarding accepts the private IP directly; the HTTP reverse-proxy mode routes by DNS name. The phone's server origin is `http://100.x.x.x:8765`; the Windows app keeps `http://127.0.0.1:8765`. Serve shares this listener privately within the tailnet, and the device token is still required. No public Funnel or router port forwarding is needed. Keep this PC awake with the server and Tailscale running. The proxy persists, and the normal launcher reloads the saved server settings after a restart.

If HTTPS is already enabled for your tailnet, use `tailscale serve --bg --https=443 http://127.0.0.1:8765` and the matching HTTPS DNS origin instead. Add that DNS name to `allowed_hosts`. Stop only the listener you configured with `tailscale serve --tcp=8765 off` or `tailscale serve --https=443 off`; do not reset unrelated Serve configurations. Account setup is disabled while shared. To reconnect accounts, turn off the proxy and run the interactive `auth youtube` / `auth tidal` CLI commands, or temporarily restore local setup and restart on loopback. Environment variables override the settings file for local setup; `RADIO_ALLOWED_HOSTS` adds further host names.

Alternatively, to bind directly to the Tailscale interface, stop the existing loopback instance and run from the repository root:

```powershell
.venv\Scripts\python.exe -m radio_prototype serve --host YOUR_PC_TAILSCALE_IP
```

Use the actual numeric `100.x.x.x` address from Tailscale. This disables account setup on that listener, binds only to that address, and permits its Host header. Authenticate/reconnect accounts through loopback setup before switching listeners. Any firewall rule must be restricted to the Tailscale interface/network. The launcher defaults to a local server; when using a Tailscale listener, open the executable directly and change Connection settings.

## Playback and saved state

The player uses media_kit/libmpv with authenticated FLAC URLs and no server audio conversion. The source is requested at Hi-Res lossless first, then standard lossless. The quality badge shows actual bit depth/sample rate only when the server's ffprobe check succeeds. Hardware bit-perfect output is not asserted.

Search, stations, queue, saved match corrections, play/pause, seek, skip, explicit like/dislike, volume (Windows), reporting outcomes, and local listening statistics are included. Skipped uncertain recordings remain visible with a reason. The queue's correction icon accepts a deliberate Tidal track ID. A skip never creates a dislike. Selected thumbs are filled and highlighted; click the selected thumb again to clear it. The caption shows whether the action is queued on this device, being sent, acknowledged, verified, or uncertain. Rating selections are retained across app restarts and synchronized from the server’s existing activity records. Dislike acknowledgements are shown as sent without claiming independent account verification.

Android uses audio_service's foreground media service and audio_session for notification/lock-screen controls, headset buttons, unplug handling, audio focus, ducking and interruptions. Physical-device screen-off, headset and interruption acceptance checks remain necessary. On restrictive Android builds, allow background playback for Personal Radio in the phone's battery settings if playback is stopped by the OS.

**Like** adds the original recommendation to YouTube likes and the matched recording to Tidal favorites. Click the selected Like again to remove it from both. Changing a Like to Dislike removes that Tidal favorite and sends the dislike to YouTube; disliking without a prior app Like does not remove existing Tidal favorites. The caption shows each service's pending, sent, verified or uncertain state separately, and these statuses survive restart. One account being unavailable does not undo a successful update on the other. Update the server together with the player to enable this behavior. Earlier likes are not copied retroactively.

For music-video recommendations, the server prefers YouTube's audio counterpart or resolves matching official-song metadata before comparing Tidal durations. Video intros and labels such as "Lyric Video" do not by themselves change the recording. **Retry skipped matches** rechecks the existing queue without changing occurrences, playback position or pending listening events. The correction button shows available Tidal candidates with album, duration and explicit status; choosing one deliberately saves that mapping. Different recording identifiers can still require this choice.

Queue occurrences and events have stable UUIDs. The JSON outbox is flushed to disk before transmission, with a recoverable previous snapshot. Actual time uses monotonic time and media progress, excluding pause, buffering, mute and seek jumps. App restart restores the same occurrence and saved position, paused until Play. Stream errors renew the URL and resume, with bounded retries. A server restart invalidates its in-memory stream URLs; press Play to reconnect if automatic recovery fails. A device lease is renewed every six seconds while playing; Take over moves the lease, and the old device pauses on its next heartbeat.

Pending events are local until the server acknowledges them. The Listening screen distinguishes provider submissions and uncertain outcomes. Eligible history reports start after 30 seconds, or natural completion of a shorter track with essentially all its time heard. Provider mutations with ambiguous outcomes are never blindly retried. Recap inclusion remains unverified.

Windows state is under `%APPDATA%/dev.personalradio/personal_radio/`; Android state is in the app's private support directory. App uninstall removes its local outbox/state. The server keeps acknowledged listening records, matching corrections and pending provider submissions independently.

## Build

The builds were checked with Flutter 3.47.9 / Dart 3.13.7, Java 21, Windows C++ Build Tools (including ATL), and Android SDK with NDK 29.0.13113456. Install those tools yourself; SDKs and build outputs are excluded from Git. Windows builds require Windows. Dependencies are pinned in `pubspec.lock`.

```powershell
cd player
flutter pub get
flutter analyze
flutter test
flutter build windows --release
# Configure your Android signing key below before the release build:
flutter build apk --release
```

Android release signing reads `data/android-signing.properties` at the repository root. Create your own keystore using `keytool`, then create that properties file with these keys (replace all placeholders):

```properties
storeFile=C:/path/to/private/android-release.jks
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=YOUR_KEY_ALIAS
```

Use an absolute `storeFile` path with forward slashes, including on Windows. Keep the keystore and properties private and backed up: subsequent sideload updates require the same key. Both are excluded from Git. The distributed APK uses a private release key that is not part of this repository; a build signed with your own key cannot update that APK in place. Release builds require signing configuration; no debug-key fallback is used.

The opt-in Windows integration test plays real audio and submits actual listening to your paired account. Do not run it as an ordinary offline unit test:

```powershell
$env:RADIO_PAIRING_FILE = (Resolve-Path ..\data\windows-pairing.json).Path
flutter test integration_test/windows_live_test.dart -d windows
# Optional full-song natural-completion check (several minutes):
flutter test integration_test/windows_live_test.dart -d windows --dart-define=RADIO_FULL_TRACK=true
```

Offline tests use fixtures and never call your provider accounts. Release packaging requires Android SDK `aapt2` and checks the notification and media control icons in the compiled APK, because these are resolved by name and can otherwise be removed by resource shrinking. `scripts/Package-Apps.ps1` copies release outputs and writes SHA-256 checksums. No account file, pairing token, signing secret, or provider URL is included in the packages.

Discover opens on **For you** with your signed-in YouTube Music **Speed dial** and **Quick picks**. Speed dial uses a swipeable three-by-three grid with previous/next buttons for mouse and keyboard users; artist and album shortcuts open their catalog pages, and playable shortcuts use YouTube's returned play action. Quick picks offers individual song radio and the provider's **Play all** action. Song long-press/right-click menus still offer Play next, Add to queue and artist/album links. Ratings remain in now playing. Search and its **For you** button let you switch between catalog results and home recommendations.

Refresh Home with the refresh button or pull down. Refreshing keeps the current queue and pending listening events intact. The server must be updated for these shelves (API version 0.4.0). When YouTube signs the server out or omits a shelf, the app explains that instead of substituting generic recommendations. A home play selection can expire after a server restart; refresh Home and select it again. Normal queues, playback events and listening totals stay durable.
