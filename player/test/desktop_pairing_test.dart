import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:personal_radio/desktop_pairing.dart';
import 'package:personal_radio/device_peer.dart';

void main() {
  testWidgets(
    'history scanner explains a YouTube code and accepts a history QR',
    (tester) async {
      final camera = _FixtureCamera();
      final previous = MobileScannerPlatform.instance;
      MobileScannerPlatform.instance = camera;
      addTearDown(() async {
        MobileScannerPlatform.instance = previous;
        await camera.captures.close();
      });

      String? selected;
      await _openHistoryScanner(tester, (code) => selected = code);
      expect(find.text('Scan history QR'), findsOneWidget);
      expect(camera.options?.formats, [BarcodeFormat.qrCode]);

      camera.scan(_code(PairPurpose.youtube));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Choose Connect from Windows'),
        findsOneWidget,
      );
      expect(selected, isNull);

      final history = _code(PairPurpose.history);
      camera.scan(history);
      await tester.pumpAndSettle();
      expect(find.text('Scan history QR'), findsNothing);
      expect(selected, history);
    },
  );

  testWidgets('paste fallback is available directly in the scanner', (
    tester,
  ) async {
    final camera = _FixtureCamera();
    final previous = MobileScannerPlatform.instance;
    MobileScannerPlatform.instance = camera;
    final messenger = tester.binding.defaultBinaryMessenger;
    addTearDown(() async {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      MobileScannerPlatform.instance = previous;
      await camera.captures.close();
    });
    String? clipboard;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      return call.method == 'Clipboard.getData' && clipboard != null
          ? {'text': clipboard}
          : null;
    });
    String? selected;
    await _openHistoryScanner(tester, (code) => selected = code);

    await tester.tap(find.text('Paste code'));
    await tester.pumpAndSettle();
    expect(find.text('Copy a desktop pairing code first.'), findsOneWidget);
    expect(selected, isNull);

    clipboard = _code(PairPurpose.history);
    await tester.tap(find.text('Paste code'));
    await tester.pumpAndSettle();
    expect(selected, clipboard);
    expect(find.text('Scan history QR'), findsNothing);
  });
}

Future<void> _openHistoryScanner(
  WidgetTester tester,
  ValueChanged<String?> selected,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => selected(
              await receiveDesktopCode(context, PairPurpose.history),
            ),
            child: const Text('Pair Wi-Fi history'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Pair Wi-Fi history'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Scan QR'));
  await tester.pumpAndSettle();
}

String _code(PairPurpose purpose) {
  final token = List.filled(43, 'a').join();
  return PairCode(purpose, '192.168.5.12', 34567, token, token).encode();
}

class _FixtureCamera extends MobileScannerPlatform {
  final captures = StreamController<BarcodeCapture?>.broadcast();
  StartOptions? options;

  void scan(String code) => captures.add(
    BarcodeCapture(
      barcodes: [Barcode(format: BarcodeFormat.qrCode, rawValue: code)],
    ),
  );

  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    options = startOptions;
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.off,
      size: Size(1280, 720),
    );
  }

  @override
  Widget buildCameraView() => const SizedBox.expand();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
