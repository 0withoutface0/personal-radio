import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'support/player_fixture.dart';

void main() {
  test(
    'batch replay uses durable event IDs and dispatches only eligible reports',
    () async {
      final fixture = PlayerFixture();
      addTearDown(fixture.dispose);
      final radio = fixture.radio;
      radio.api!.supportsEventBatches = true;
      final events = [
        for (var n = 0; n < 3; n++)
          {
            'id': 'outbox-$n',
            'path': '/api/events',
            'body': {
              'id': 'event-$n',
              'occurrence_id': 'occurrence',
              'seconds': 1,
              'played_at': '2026-11-10T10:00:0${n}Z',
            },
          },
      ];
      radio.outbox.addAll(events);
      await radio.persist();
      var calls = 0;
      final batches = <Object?>[];
      fixture.catalog = (request) async {
        if (request.url.path == '/api/events/batch') {
          final body = jsonDecode(request.body) as Map;
          batches.add(body['events']);
          final saved = await radio.disk.load();
          expect(saved['outbox'], events);
          calls++;
          return {'accepted': calls == 1 ? 2 : 3, 'reporting': false};
        }
        fail('Unexpected request: ${request.url.path}');
      };
      await radio.sync(force: false);
      expect(radio.outbox, events);
      await radio.sync(force: false);
      await radio.sync(force: false);
      expect(batches, [
        events.map((event) => event['body']).toList(),
        batches.first,
      ]);
      expect(radio.outbox, isEmpty);
      expect((await radio.disk.load())['outbox'], isEmpty);
    },
  );
}
