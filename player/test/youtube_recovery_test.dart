import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_radio/api.dart';
import 'package:personal_radio/local_settings.dart';
import 'package:personal_radio/player_host.dart';
import 'package:personal_radio/radio_controller.dart';

import 'support/player_fixture.dart';

void main() {
  testWidgets('held YouTube activity waits for explicit channel confirmation', (
    tester,
  ) async {
    final radio = RadioController(MemoryDisk(), localMode: true)
      ..connected = true
      ..localAccounts = {
        'youtube': {
          'credential_file': true,
          'label': '@fixture',
          'reporting': true,
        },
      };
    final host = PlayerHost()..radio = radio;
    addTearDown(host.dispose);
    addTearDown(radio.dispose);
    var approvals = 0;
    radio.api = RadioApi(
      'http://127.0.0.1:8765',
      'fixture',
      radio.deviceId,
      client: MockClient((request) async {
        if (request.url.path == '/api/local/accounts/youtube/recovery') {
          if (request.method == 'POST') {
            expect(jsonDecode(request.body), {'confirmation': 'fixture-token'});
            approvals++;
            return http.Response('{"reviewed":2}', 200);
          }
          return http.Response(
            '{"count":2,"label":"@fixture","confirmation":"fixture-token"}',
            200,
          );
        }
        expect(
          request.url.path,
          anyOf('/api/reporting/dispatch', '/api/report'),
        );
        return http.Response('{}', 200);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showLocalSettings(context, host),
              child: const Text('Settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    final review = find.text('Review held YouTube activity');
    Future<void> openReview() async {
      await tester.ensureVisible(review);
      await tester.pumpAndSettle();
      await tester.tap(review);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Send held YouTube activity?'), findsOneWidget);
      expect(find.textContaining('2 pending YouTube reports'), findsOneWidget);
    }

    await openReview();
    expect(approvals, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(approvals, 0);

    await openReview();
    await tester.tap(find.text('Send to @fixture'));
    await tester.pumpAndSettle();
    expect(approvals, 1);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });
}
