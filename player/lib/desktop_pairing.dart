import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'device_peer.dart';

Future<bool> showDesktopPairing(
  BuildContext context,
  DevicePeer peer,
  PairPurpose purpose,
) async {
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
  final offer = await peer.offer(address, purpose);
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
    title: Text(
      offer.code.purpose == PairPurpose.youtube
          ? 'Connect YouTube on Android'
          : 'Pair Android listening history',
    ),
    content: SizedBox(
      width: 320,
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
              if (decided)
                const LinearProgressIndicator()
              else
                FilledButton(
                  onPressed: () {
                    setState(() => decided = true);
                    offer.decide(true);
                  },
                  child: const Text('Approve phone'),
                ),
            ] else ...[
              const Text(
                'Use the matching pairing option on your phone while both devices are on the same private network. The code expires in five minutes.',
              ),
              const SizedBox(height: 12),
              QrImageView(
                data: offer.code.encode(),
                size: 225,
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
      title: const Text('Pair with Windows'),
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
  if (selection == 'paste') {
    final code = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (code == null) throw const FormatException('Copy a desktop code first.');
    return code;
  }
  if (selection != 'scan' || !context.mounted) return null;
  return Navigator.of(context)
      .push<String>(MaterialPageRoute(builder: (_) => _PairScanner(purpose)));
}

class _PairScanner extends StatefulWidget {
  const _PairScanner(this.purpose);
  final PairPurpose purpose;

  @override
  State<_PairScanner> createState() => _PairScannerState();
}

class _PairScannerState extends State<_PairScanner> {
  bool found = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan desktop pairing code')),
    body: MobileScanner(
      errorBuilder: (context, error) => const Center(
        child: Text('Camera unavailable. Go back and paste the desktop code.'),
      ),
      onDetect: (capture) {
        if (found || !mounted) return;
        for (final barcode in capture.barcodes) {
          final code = barcode.rawValue;
          if (code == null) continue;
          try {
            PairCode.decode(code, widget.purpose);
          } on FormatException {
            continue;
          }
          found = true;
          Navigator.pop(context, code);
          return;
        }
      },
    ),
  );
}
