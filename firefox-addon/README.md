# Personal Radio Connect

This Firefox WebExtension connects an existing YouTube Music browser session to the standalone Personal Radio app. The public add-on requires Mozilla signing and review. Release builds keep the option disabled until a signed add-on is available.

For development, load the manifest as a temporary add-on in desktop Firefox using about:debugging. In a debug Personal Radio build, open **Settings → On this device → Connect with Firefox**. Open the setup URL in Firefox if it opened in a different browser. Select the add-on and choose **Connect this session**. Complete sign-in on the Music tab if prompted, then choose **Check accounts** in Personal Radio. Android uses the same extension source and requires a Firefox build that can install the signed add-on or a development Firefox instance configured for remote add-on debugging.

The add-on inspects signed-in browse request headers from the Music tab it opened. It sends the relevant authentication headers once, directly to the one-time loopback endpoint on the same device. The add-on keeps the headers in memory only. Personal Radio validates the session and stores it encrypted on the device. There are no analytics or external relay services. Cancel in the add-on or close either setup tab to stop the capture.

Run the fixture test with `node --test firefox-addon/background.test.js`. Exclude the fixture and this README from the Mozilla package.
