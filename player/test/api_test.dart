import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_radio/api.dart';

void main() {
  test('pairing accepts loopback, Tailscale and HTTPS origins', () {
    expect(validateServer('http://100.99.2.3:8765/'), 'http://100.99.2.3:8765');
    expect(
      validateServer('https://radio.tailnet.ts.net'),
      'https://radio.tailnet.ts.net',
    );
    expect(validateServer('http://127.0.0.1:8765'), 'http://127.0.0.1:8765');
    for (final invalid in [
      'http://example.com',
      'https://token@example.com',
      'https://example.com/?token=secret',
      'https://example.com/path',
      'file:///tmp',
    ]) {
      expect(() => validateServer(invalid), throwsFormatException);
    }
  });

  test(
    'auth and stable event identifiers travel in headers and JSON',
    () async {
      final client = RadioApi(
        'http://127.0.0.1:8765',
        'access',
        'device',
        client: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer access');
          expect(request.headers['X-Device-ID'], 'device');
          expect(request.url.query, isEmpty);
          expect(request.method, 'POST');
          expect(jsonDecode(request.body)['id'], 'event');
          return http.Response('{"inserted":false}', 200);
        }),
      );
      expect(
        (await client.call('/api/events', body: {'id': 'event'}))['inserted'],
        false,
      );
      client.close();
    },
  );
}
