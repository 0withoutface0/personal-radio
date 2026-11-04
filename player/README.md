# Personal Radio apps

One Flutter application targets Windows x64 and Android 7.0+ (API 24). Discover offers separate **Songs**, **Artists** and **Albums** searches. The play button plays a song directly without creating radio. Artist pages show top songs, albums and singles/EPs; album pages show the ordered track list, **Play album**, and playback starting at a selected track. Song actions also offer **Autoplay** and **Start radio / mix**. Stations uses the personalized mixes discovered from your account.

Browsing uses your YouTube Music catalog. Song actions include **View artist** and **View album** where those links are supplied; album artist names open their pages. All songs still pass through the conservative Tidal matcher and original lossless stream proxy. Unavailable or uncertain recordings remain visible in Queue. Direct playback creates a finite queue; it does not enable recommendations automatically. A deliberate new Play creates new occurrence IDs while resuming the current occurrence keeps its saved ID.

## Run

Configure the server first using the [root setup guide](../README.md). The player does not include account credentials or an embedded server.

For a local source checkout with the Python environment and Windows release already prepared, double-click `Start Personal Radio.cmd` at the repository root. It starts the local Python service if necessary and opens the Windows release. Account files remain in `data/`. The launcher pairs the app using the device token; Flutter stores it using platform secure storage.

For a standalone Windows install, download `PersonalRadio-Windows-x64.zip` from [Releases](https://github.com/0withoutface0/youtube-tidal-radio/releases), unzip it and run `personal_radio.exe`. Keep its DLLs, notices and asset `data` folder beside it. This asset folder is different from the server's private `data/`. In Connection settings, enter your private server origin and the contents of the server's `data/device-token.txt`. The app requires the Microsoft Visual C++ 2015-2022 x64 runtime; install Microsoft's redistributable if it is missing.

Download `PersonalRadio-Android.apk` from Releases, copy it to your phone, allow installation from the app you use to open it, and install. Connect Tailscale on the phone. In Connection settings, enter `http://YOUR_PC_TAILSCALE_IP:8765` or your private HTTPS origin, plus the device token. `localhost` on Android means the phone, not the server. The Android emulator can use `http://10.0.2.2:8765` with that host added to `RADIO_ALLOWED_HOSTS` on the server. Provider cookies and Tidal session tokens belong only on the server.

To make the Windows-hosted server reachable from the phone, stop its existing loopback instance, then run from the repository root:

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

Offline tests use fixtures and never call your provider accounts. `scripts/Package-Apps.ps1` copies release outputs and writes SHA-256 checksums. No account file, pairing token, signing secret, or provider URL is included in the packages.
