import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:personal_radio/models.dart';
import 'package:personal_radio/radio_controller.dart';

import 'support/player_fixture.dart';

void main() {
  late PlayerFixture f;
  late RadioAudioHandler handler;
  late List<Map<String, dynamic>> ratings;
  var offline = false;
  setUp(() {
    f = PlayerFixture();
    ratings = [];
    offline = false;
    f.radio.entries = [
      QueueEntry(song('one'), tidal: {'id': 123}),
    ];
    f.radio.currentIndex = 0;
    f.catalog = (request) async {
      if (offline) throw http.ClientException('Fixture offline');
      if (request.url.path == '/api/ratings') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(
          (await f.radio.disk.load())['outbox'].any(
            (e) => e['body']['id'] == body['id'],
          ),
          true,
        );
        ratings.add(body);
        return {'queued': true};
      }
      if (request.url.path == '/api/report') return {'submissions': []};
      if (request.url.path == '/api/reporting/dispatch')
        return {'queued': true};
      throw StateError('Unexpected fixture request');
    };
    handler = RadioAudioHandler(f.radio);
  });
  tearDown(() => f.dispose());
  MediaControl control() => handler.playbackState.value.controls.singleWhere(
    (x) => x.customAction?.name == RadioAudioHandler.likeAction,
  );

  test(
    'notification likes both services, displays filled state and clears once',
    () async {
      final initial = control().customAction!;
      expect(control().androidIcon, endsWith('outline'));
      await handler.customAction(initial.name, initial.extras);
      expect(ratings.single['value'], 'LIKE');
      expect(ratings.single['tidal_favorite'], true);
      expect(control().androidIcon, endsWith('filled'));
      expect(handler.mediaItem.value!.rating!.hasHeart(), true);
      await handler.customAction(initial.name, initial.extras);
      expect(ratings.length, 1);
      final clear = control().customAction!;
      await handler.customAction(clear.name, clear.extras);
      expect(ratings.length, 2);
      expect(ratings.last['value'], 'INDIFFERENT');
      expect(ratings.last['tidal_favorite'], false);
      await handler.customAction(clear.name, clear.extras);
      expect(ratings.length, 2);
      expect(f.radio.outbox, isEmpty);
    },
  );

  test('stale notification cannot rate a new occurrence and unmatched tracks hide Like', () async {
    final old = control().customAction!;
    f.radio.entries.add(QueueEntry(song('two'), tidal: {'id': 234}));
    f.radio.currentIndex = 1;
    f.radio.update();
    await handler.customAction(old.name, old.extras);
    expect(f.requests, isEmpty);
    expect(f.radio.ratings, isEmpty);
    f.radio.current!.tidal = null;
    f.radio.update();
    expect(
      handler.playbackState.value.controls.where(
        (x) => x.customAction?.name == RadioAudioHandler.likeAction,
      ),
      isEmpty,
    );
  });

  test(
    'system heart action queues a durable dual-service Like while offline',
    () async {
      offline = true;
      await handler.setRating(const Rating.newHeartRating(true));
      expect(f.radio.outbox.single['body']['value'], 'LIKE');
      expect(f.radio.outbox.single['body']['tidal_favorite'], true);
      expect(f.radio.currentRating!.value, 'LIKE');
      final saved = await f.radio.disk.load();
      expect(
        saved['outbox'].single['body']['id'],
        f.radio.outbox.single['body']['id'],
      );
      await handler.setRating(const Rating.newHeartRating(true));
      expect(f.radio.outbox.length, 1);
      expect(ratings, isEmpty);
      expect(control().androidIcon, endsWith('filled'));
    },
  );
}
