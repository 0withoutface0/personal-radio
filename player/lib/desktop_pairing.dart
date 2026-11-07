import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'api.dart';
import 'device_peer.dart';
import 'player_host.dart';

Future<bool> showDesktopPairing(
  BuildContext context,
  DevicePeer peer,
  PairPurpose purpose, {
  bool shareHistory = false,
  ServerConnection? serverConnection,
}) async {
  final addresses = await lanAddresses();
  if (addresses.isEmpty) {
    throw const FormatException('Connect this PC to your private Wi-Fi first.');
  }
  if (!context.mounted) return false;
  final address = addresses.length == 1
      ? addresses.first
      : await showDialog(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Choose this PC’s Wi-Fi or Ethernet address'),
            children: [
              for (final address in addresses)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, address),
                  child: Text(address.address),
                ),
            ],
          ),
        );
  if (address == null || !context.mounted) return false;
  final offer = await peer.offer(
    address,
    purpose,
    shareHistory: shareHistory,
    serverConnection: serverConnection,
  );
  try {
    if (!context.mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (_) => _DesktopCode(offer),
        ) ??
        false;
  } finally {
    await peer.closeOffer();
  }
}

Future<void> showDeviceSetup(BuildContext context, PlayerHost host) async {
  if (host.changing) return;
  if (Platform.isAndroid) {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _PairScanner(PairPurpose.setup)),
    );
    if (code == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SetupProgress(host, code),
    );
    return;
  }

  final radio = host.radio;
  try {
    final local = radio.localMode;
    if (!radio.ready ||
        (local &&
            (!radio.accountLinked('youtube') ||
                !radio.accountLinked('tidal')))) {
      throw const FormatException(
        'Connect Windows to your music accounts or server first.',
      );
    }
    final server = local ? null : shareableServer(radio.origin, radio.token);
    var shareHistory = false;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Set up Android'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                local
                    ? 'Give a phone you trust access to your signed-in YouTube Music and Tidal accounts.'
                    : 'Connect a phone you trust to this app’s saved server.',
              ),
              if (local && !host.peer.paired)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include Wi-Fi listening history sync'),
                  value: shareHistory,
                  onChanged: (value) =>
                      setDialog(() => shareHistory = value == true),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Show setup QR'),
            ),
          ],
        ),
      ),
    );
    if (approved != true || !context.mounted || host.radio != radio) return;
    await showDesktopPairing(
      context,
      host.peer,
      PairPurpose.setup,
      shareHistory: shareHistory,
      serverConnection: server,
    );
  } catch (error) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Set up Android'),
        content: Text(
          error is FormatException
              ? error.message
              : 'Could not open setup. Check your private Wi-Fi and try again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _SetupProgress extends StatefulWidget {
  const _SetupProgress(this.host, this.code);
  final PlayerHost host;
  final String code;

  @override
  State<_SetupProgress> createState() => _SetupProgressState();
}

class _SetupProgressState extends State<_SetupProgress> {
  var installing = false;
  var finished = false;
  var message = 'Approve this phone in Personal Radio on Windows.';

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  Future<void> _connect() async {
    final host = widget.host;
    try {
      await host.peer.acceptSetup(widget.code, (setup) async {
        if (!mounted) throw const FormatException('Setup was cancelled.');
        setState(() {
          installing = true;
          message = 'Checking the settings and connecting this phone…';
        });
        await host.installDesktopSetup(setup);
      });
      message = 'Setup complete. Your phone is ready to play.';
    } catch (error) {
      message = switch (error) {
        ApiFailure(:final message) => message,
        FormatException(:final message) => message,
        _ => 'Could not complete setup. Keep both devices on the same private network and try a new code.',
      };
      if (!mounted && installing) host.radio.fail(FormatException(message));
    }
    if (mounted) setState(() => finished = true);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !installing || finished,
    child: AlertDialog(
      title: const Text('Set up from Windows'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          if (!finished) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: installing && !finished
              ? null
              : () => Navigator.pop(context),
          child: Text(finished ? 'Done' : 'Cancel'),
        ),
      ],
    ),
  );
}

class _DesktopCode extends StatefulWidget {
  const _DesktopCode(this.offer);
  final PairOffer offer;

  @override
  State<_DesktopCode> createState() => _DesktopCodeState();
}

class _DesktopCodeState extends State<_DesktopCode> {
  PairOffer get offer => widget.offer;
  String? failure;
  bool decided = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      offer.finished.future
          .timeout(
            offer.expires.difference(DateTime.now()),
            onTimeout: () => false,
          )
          .then((success) {
            if (!mounted) return;
            if (success) {
              Navigator.pop(context, true);
            } else {
              setState(
                () => failure =
                    'Pairing ended. Close this window to start again.',
              );
            }
          }),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(switch (offer.code.purpose) {
      PairPurpose.youtube => 'Connect YouTube on Android',
      PairPurpose.history => 'Pair Android listening history',
      PairPurpose.setup => 'Set up Android',
    }),
    content: SizedBox(
      width: 380,
      child: ValueListenableBuilder<String?>(
        valueListenable: offer.incoming,
        builder: (context, incoming, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failure != null)
              Text(failure!)
            else if (incoming != null) ...[
              Text(
                'Approve the phone at $incoming only if you just scanned this code.',
              ),
              if (decided) ...[
                if (offer.code.purpose == PairPurpose.setup)
                  const Text('Waiting for Android to finish setup…'),
                const LinearProgressIndicator(),
              ] else
                FilledButton(
                  onPressed: () {
                    setState(() => decided = true);
                    offer.decide(true);
                  },
                  child: const Text('Approve phone'),
                ),
            ] else ...[
              Text(
                'On your phone, choose ${offer.code.purpose.androidAction}. Keep both '
                'devices on the same private network. The code expires in five minutes.',
              ),
              const SizedBox(height: 12),
              QrImageView(
                data: offer.code.encode(),
                size: 340,
                padding: const EdgeInsets.all(28),
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: offer.code.encode()),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Temporary pairing code copied.'),
                      ),
                    );
                  }
                },
                child: const Text('Copy code'),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Close'),
      ),
    ],
  );
}

Future<String?> receiveDesktopCode(
  BuildContext context,
  PairPurpose purpose,
) async {
  final selection = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        purpose == PairPurpose.youtube
            ? 'Connect YouTube from Windows'
            : 'Pair listening history with Windows',
      ),
      content: Text(
        purpose == PairPurpose.youtube
            ? 'Import a YouTube Music session from Windows. Use this only with a PC and an account you trust.'
            : 'Exchange listening history with Windows. Both devices keep their own queue, accounts, and provider reporting.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, 'paste'),
          child: const Text('Paste code'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'scan'),
          child: const Text('Scan QR'),
        ),
      ],
    ),
  );
  if (selection == 'paste') return _readDesktopCode();
  if (selection != 'scan' || !context.mounted) return null;
  return Navigator.of(context)
      .push<String>(MaterialPageRoute(builder: (_) => _PairScanner(purpose)));
}

Future<String> _readDesktopCode() async {
  final code = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  if (code == null || code.trim().isEmpty) {
    throw const FormatException('Copy a desktop pairing code first.');
  }
  return code;
}

class _PairScanner extends StatefulWidget {
  const _PairScanner(this.purpose);
  final PairPurpose purpose;

  @override
  State<_PairScanner> createState() => _PairScannerState();
}

class _PairScannerState extends State<_PairScanner>
    with WidgetsBindingObserver {
  final scanner = MobileScannerController(
    cameraResolution: const Size(1280, 720),
    formats: const [BarcodeFormat.qrCode],
  );
  bool found = false;
  String? feedback;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (found || !scanner.value.hasCameraPermission) return;
    if (state == AppLifecycleState.resumed) unawaited(scanner.start());
    if (state == AppLifecycleState.inactive) unawaited(scanner.stop());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(scanner.dispose());
    super.dispose();
  }

  void _showFeedback(String message) {
    if (mounted && !found && message != feedback) {
      setState(() => feedback = message);
    }
  }

  bool _accept(String code) {
    if (found || !mounted) return false;
    try {
      PairCode.decode(code, widget.purpose);
    } on FormatException catch (error) {
      _showFeedback(error.message);
      return false;
    }
    found = true;
    Navigator.pop(context, code);
    return true;
  }

  Future<void> _paste() async {
    try {
      _accept(await _readDesktopCode());
    } on FormatException catch (error) {
      _showFeedback(error.message);
    } on PlatformException {
      _showFeedback(
        'Could not read the clipboard. Try copying the desktop code again.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(switch (widget.purpose) {
        PairPurpose.youtube => 'Scan YouTube sign-in QR',
        PairPurpose.history => 'Scan history QR',
        PairPurpose.setup => 'Scan setup QR',
      }),
    ),
    body: Column(
      children: [
        Expanded(
          child: MobileScanner(
            controller: scanner,
            tapToFocus: true,
            errorBuilder: (context, error) => const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Camera unavailable. Allow camera access in Android settings or paste the code below.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            onDetect: (capture) {
              for (final barcode in capture.barcodes) {
                final code = barcode.rawValue;
                if (code != null && _accept(code)) return;
              }
            },
          ),
        ),
        SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  feedback ?? 'Fit the whole QR square in view. Tap the preview to focus.',
                  textAlign: TextAlign.center,
                ),
              ),
              TextButton(onPressed: _paste, child: const Text('Paste code')),
            ],
          ),
        ),
      ],
    ),
  );
}
