# Standalone Personal Radio

## Set up either mode

- **On this device** runs the engine on your Windows PC or Android phone and connects directly to YouTube Music and Tidal. A separate server, Docker, Python installation and Tailscale are unnecessary for this mode. It is the default for new installations of a standalone-capable build.
- **Connect to a server** uses the existing server and device-access token. Upgrades keep this mode if they already have a server profile. The ARMv7 Android package offers server mode.

On Windows, run the per-user installer or extract the entire ZIP and launch **personal_radio.exe**. Keep the executable beside the bundled DLLs, data and engine directories. On Android, sideload the signed APK. Standalone requires arm64 or x86_64 and Android 7.0 or newer. An upgrade needs the same Android signing key as the installed app.

Open the gear menu to switch modes. Each mode keeps its own queue, pending activity and account setup. Listening recorded by the server stays there. A standalone account or saved queue is available again when you switch back to **On this device**.

## Connect accounts

Open **Settings → On this device**.

- **YouTube Music on Windows**. Choose **Paste request headers** after copying the request headers for an authenticated Music browse request, or choose **Import browser-auth JSON** for a browser-auth file. For the manual capture steps see [ytmusicapi browser authentication](https://ytmusicapi.readthedocs.io/en/stable/setup/browser.html).
- **YouTube Music on Android**. In a signed-in standalone Windows app, choose **Pair Android for YouTube**. In Android Settings choose **Connect from Windows**, then scan the QR or paste the temporary code. Both devices must be on the same private network and Windows must approve the request. If Windows prompts about the firewall, allow access on your trusted private network. Codes expire after five minutes. Android can also accept pasted headers or a browser-auth JSON file.
- **Firefox**. The browser helper source is in [firefox-addon](../firefox-addon/README.md). In a compatible development build, open **Connect with Firefox** from Settings, open the add-on on the setup page, and explicitly approve capture. Choose **Check accounts** when it finishes. Distributed builds require Mozilla signing and review before enabling this option.
- **Tidal**. Choose **Open Tidal sign-in** and sign in with your own subscription in the system browser. Copy the final HTTPS redirect URL to finish setup. Android can also share the final URL to Personal Radio, then choose **Finish Tidal sign-in**. Use the browser’s address bar or share action on the final page. Each device completes its own Tidal sign-in.

The app validates the imported YouTube session. Listening and ratings stay pending if it cannot verify the channel or if a different account is connected. Sign back into the originating account to release those records. Recap remains independently unverified.

## Share listening history

Wi-Fi sharing is optional and works separately from YouTube pairing. Open **Pair Wi-Fi history** on Windows and Android. Scan or paste the Windows code on Android, then approve on Windows. Keep both apps open on the same private network. Android syncs while the app is in use and offers **Sync history now**. If the Windows Wi-Fi address changes, unpair on both devices and pair again. Unpairing keeps history already imported.

For a file transfer, choose **Export encrypted history**, set a passphrase and save the .prh file. On the other device choose **Import encrypted history** and enter the same passphrase. Each file supports up to 64 MiB. Existing events are deduplicated. Sharing transfers track labels and listening events. Provider credentials, ratings, queue state, resume positions and pending provider submissions remain with the original mode and device.

## Build the standalone packages

Use the [player toolchain](README.md#build), Python 3.13, uv, and Android NDK 29.0.13113456. On Windows use an x64 CPython build and the redistributable x64 Microsoft.VC142.CRT or later DLL directory from the matching Visual Studio toolchain. Use Inno Setup 6.3+ to compile the optional per-user installer.

1. Create an isolated Python 3.13 environment. Install the locked engine packages with **uv pip sync requirements.lock**, then install **pyinstaller==6.22.3** and **maturin==1.11.5** in that build environment.
2. Run **scripts/Build-WindowsEngine.ps1 -Python <venv-python.exe> -OutputDirectory <engine-output>**. Build Flutter Windows with **flutter build windows --release** in the player directory.
3. Install Rust 1.93.0 and the **aarch64-linux-android** and **x86_64-linux-android** Rust targets. Run **python scripts/build_android_wheels.py <wheels-directory> <NDK-host-bin-directory>** with that toolchain on PATH. The NDK bin directory is under **toolchains/llvm/prebuilt/<host>/bin**. The script verifies the input archives and builds the missing Chaquopy wheels.
4. Set **RADIO_ANDROID_WHEELS** to the absolute wheels directory and configure the project's Android signing key. Run **flutter build apk --release --target-platform android-arm64,android-x64** in the player directory. Save that APK before building the optional ARMv7 variant.
5. For ARMv7, unset **RADIO_ANDROID_WHEELS** and run **flutter build apk --release --target-platform android-arm --split-per-abi**. This omits the embedded engine.
6. Run **scripts/Package-Apps.ps1** with a new **-OutputDirectory**, **-EngineDirectory** set to the built personal_radio_engine directory, **-CrtDirectory** pointing to the x64 CRT, and **-AndroidApk** pointing to the saved 64-bit APK. Pass **-InstallerCompiler** with the path to ISCC.exe and **-AndroidServerOnlyApk** with the ARMv7 APK to include them in the output. Packaging writes SHA-256 checksums. Windows Authenticode signing requires a separate publisher certificate.

Use a fresh emulator or other disposable test installation for **player/integration_test/standalone_fixture_test.dart**. It starts and restarts the actual packaged engine, checks loopback authorization and reads history. On Windows stage the engine next to the test runner before starting the fixture. The Python suite tests FLAC and Hi-Res source metadata and proxying with generated audio. Desktop pairing, Wi-Fi history and encrypted files have separate fixture tests.

Before public preview, verify full lossless playback, manual account setup, phone-to-PC pairing, and history sharing using dedicated accounts on Windows and a physical Android device. Verify browser add-on installation and sign-in after Mozilla signs the add-on. Treat YouTube history reporting and Recap as separate checks.
