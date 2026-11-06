import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_radio/api.dart';

void main() {
  for (final stalledBody in [false, true]) {
    test(
      'one deadline covers stalled ${stalledBody ? 'body' : 'headers'} without retrying writes',
      () async {
        var calls = 0;
        Future<void>? aborted;
        final body = StreamController<List<int>>();
        final headers = Completer<http.StreamedResponse>();
        final client = RadioApi(
          'http://127.0.0.1:8765',
          'access',
          'device',
          client: MockClient.streaming((request, _) async {
            calls++;
            aborted = (request as http.Abortable).abortTrigger;
            if (stalledBody) return http.StreamedResponse(body.stream, 200);
            return headers.future;
          }),
        );
        await expectLater(
          client.call(
            '/api/events',
            body: {'id': 'same-event'},
            timeout: const Duration(milliseconds: 20),
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(calls, 1);
        await expectLater(aborted, completes);
        if (stalledBody) {
          body.add(utf8.encode('{}'));
          await body.close();
        } else {
          headers.complete(
            http.StreamedResponse(Stream.value(utf8.encode('{}')), 200),
          );
        }
        client.close();
      },
    );
  }
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
