import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_radio/local_settings.dart';
import 'package:personal_radio/player_host.dart';

import 'support/player_fixture.dart';

void main() {
  testWidgets('header guide reads the clipboard only after Paste and connect', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 650));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = PlayerFixture();
    final host = PlayerHost()..radio = fixture.radio;
    addTearDown(host.dispose);
    addTearDown(fixture.dispose);
    var reads = 0;
    var headers = '';
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        reads++;
        return {'text': headers};
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    fixture.catalog = (request) async {
      expect(request.url.path, '/api/local/accounts/youtube');
      expect(jsonDecode(request.body), {'text': headers});
      return {};
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showLocalSettings(context, host),
              child: const Text('Settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    Future<void> openGuide() async {
      await tester.tap(find.text('Paste request headers'));
      await tester.pumpAndSettle();
    }

    await openGuide();
    expect(find.text('Copy YouTube Music request headers'), findsOneWidget);
    expect(find.textContaining('Copy > Copy Request Headers'), findsOneWidget);
    expect(find.textContaining('Chrome or Edge'), findsWidgets);
    expect(reads, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(fixture.requests, isEmpty);

    await openGuide();
    await tester.tap(find.text('Paste and connect'));
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(fixture.requests, isEmpty);
    expect(
      find.textContaining('before tapping Paste and connect'),
      findsOneWidget,
    );

    headers = 'Cookie: fixture-only\nAuthorization: fixture-only';
    await openGuide();
    await tester.tap(find.text('Paste and connect'));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(fixture.requests, hasLength(1));
    expect(find.text('YouTube Music connected.'), findsOneWidget);
    expect(find.textContaining('fixture-only'), findsNothing);
  });
}
