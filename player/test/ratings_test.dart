import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_radio/api.dart';
import 'package:personal_radio/app.dart';
import 'package:personal_radio/disk.dart';
import 'package:personal_radio/models.dart';
import 'package:personal_radio/radio_controller.dart';

class MemoryDisk extends RadioDisk {
  Map<String, dynamic> saved = {};
  MemoryDisk() : super(File('unused-rating-widget-state.json'));
  @override
  Future<void> save(Map<String, dynamic> state) async {
    saved = Map<String, dynamic>.from(jsonDecode(jsonEncode(state)));
  }

  @override
  Future<Map<String, dynamic>> load() async => saved;
  @override
  Future<void> get settled => Future.value();
}

class RatingFixture {
  final RadioController radio;
  final List<Map<String, dynamic>> writes = [];
  final List<Map<String, dynamic>> submissions = [];
  bool offline = false,
      uncertain = false,
      tidalPending = false,
      youtubeUncertain = false;
  RatingFixture(this.radio) {
    radio.connected = true;
    radio.entries = [
      QueueEntry(
        Song({
          'video_id': 'song',
          'title': 'Song',
          'artists': ['Artist'],
          'duration': 180,
        }),
        tidal: {'id': 1},
      ),
    ];
    radio.currentIndex = 0;
    radio.duration = const Duration(seconds: 180);
    radio.api = RadioApi(
      'http://127.0.0.1:8765',
      'test',
      radio.deviceId,
      client: MockClient((request) async {
        if (offline) throw http.ClientException('offline');
        if (request.url.path == '/api/ratings') {
          final body = Map<String, dynamic>.from(jsonDecode(request.body));
          // A click must reach durable disk before it can reach the server.
          final saved = await radio.disk.load();
          expect(
            (saved['outbox'] as List).any((e) => e['body']['id'] == body['id']),
            true,
          );
          if (!writes.any((e) => e['id'] == body['id'])) {
            writes.add(body);
            submissions.add({
              'id': body['id'],
              'kind': 'rating:${body['id']}',
              'video_id': 'song',
              'value': body['value'],
              'state': uncertain || youtubeUncertain
                  ? 'uncertain'
                  : body['value'] == 'LIKE'
                  ? 'visible'
                  : 'submitted',
              'detail': uncertain
                  ? 'Mutation outcome unknown; do not resend'
                  : 'Request acknowledged',
              'created': (saved['ratings']['song'] as Map)['created'],
            });
            if (body.containsKey('tidal_favorite')) {
              submissions.add({
                'id': 'tidal-${body['id']}',
                'kind': 'tidal_favorite:${body['id']}',
                'provider': 'tidal',
                'video_id': 'song',
                'tidal_id': 1,
                'value': body['tidal_favorite'] ? 'LIKE' : 'INDIFFERENT',
                'state': uncertain
                    ? 'uncertain'
                    : tidalPending
                    ? 'pending'
                    : 'visible',
                'detail': 'Tidal favorite checked',
                'created': (saved['ratings']['song'] as Map)['created'],
              });
            }
          }
          return http.Response('{"queued":true}', 200);
        }
        if (request.url.path == '/api/report') {
          return http.Response(jsonEncode({'submissions': submissions}), 200);
        }
        return http.Response('{}', 202);
      }),
    );
  }
}

void main() {
  late Directory temporary;
  late RadioController radio;
  late RatingFixture fixture;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('radio-rating-');
    radio = RadioController(RadioDisk(File('${temporary.path}/state.json')));
    fixture = RatingFixture(radio);
  });
  tearDown(() async {
    await radio.disk.settled;
    radio.api?.close();
    radio.dispose();
    for (var attempt = 0; ; attempt++) {
      try {
        await temporary.delete(recursive: true);
        break;
      } on FileSystemException catch (e) {
        // Windows may briefly retain a deleted file's directory entry after
        // all Dart writes have closed. Retry only that transient OS error.
        if (!Platform.isWindows || e.osError?.errorCode != 145 || attempt >= 4) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test(
    'clicks select immediately, toggle off, and persist before submission',
    () async {
      final pending = radio.rate('LIKE');
      expect(radio.currentRating!.value, 'LIKE');
      expect(radio.currentRating!.state, 'queued');
      await pending;
      expect(radio.currentRating!.state, 'visible');
      expect(radio.currentRating!.tidalState, 'visible');
      expect(radio.currentRating!.label, contains('Liked on Tidal'));
      await radio.rate('LIKE');
      expect(radio.currentRating!.value, 'INDIFFERENT');
      await radio.rate('DISLIKE');
      expect(radio.currentRating!.value, 'DISLIKE');
      expect(radio.currentRating!.label, 'Dislike sent to YouTube Music');
      expect(fixture.writes.map((r) => r['value']), [
        'LIKE',
        'INDIFFERENT',
        'DISLIKE',
      ]);
      expect(fixture.writes.map((r) => r['id']).toSet().length, 3);
      expect(fixture.writes.map((r) => r['tidal_favorite']).toList(), [
        true,
        false,
        null,
      ]);
      expect(radio.outbox, isEmpty);
      final restored = await radio.disk.load();
      radio.restoreRatings(restored['ratings']);
      expect(radio.currentRating!.value, 'DISLIKE');
    },
  );

  test(
    'offline feedback stays queued and retry keeps the same identifier',
    () async {
      fixture.offline = true;
      await radio.rate('LIKE');
      final eventId = radio.currentRating!.eventId;
      expect(radio.currentRating!.label, contains('waiting to send'));
      expect(radio.outbox.single['body']['id'], eventId);
      expect(fixture.writes, isEmpty);
      radio.mergeRatings([
        {
          'id': 'old',
          'kind': 'rating:old',
          'video_id': 'song',
          'value': 'DISLIKE',
          'state': 'submitted',
          'created': '2000-01-01T00:00:00Z',
        },
      ]);
      expect(radio.currentRating!.value, 'LIKE');
      fixture.offline = false;
      await radio.sync();
      expect(fixture.writes.single['id'], eventId);
      expect(radio.currentRating!.state, 'visible');
    },
  );

  test('uncertain writes are shown without sending them again', () async {
    fixture.uncertain = true;
    await radio.rate('DISLIKE');
    expect(radio.currentRating!.state, 'uncertain');
    expect(radio.currentRating!.label, contains('uncertain'));
    await radio.sync();
    expect(fixture.writes.length, 1);
  });

  test(
    'YouTube success keeps Tidal pending and restores its separate status',
    () async {
      fixture.tidalPending = true;
      await radio.rate('LIKE');
      expect(radio.currentRating!.state, 'visible');
      expect(radio.currentRating!.tidalState, 'pending');
      expect(radio.currentRating!.label, contains('Liked on YouTube Music'));
      expect(radio.currentRating!.label, contains('Tidal: sending'));
      expect(radio.currentRating!.needsStatus, true);
      radio.restoreRatings((await radio.disk.load())['ratings']);
      expect(radio.currentRating!.tidalState, 'pending');
      expect(radio.currentRating!.tidalId, 1);
      final event = radio.currentRating!.eventId;
      radio.mergeRatings([
        {
          'kind': 'tidal_favorite:older-event',
          'video_id': 'song',
          'tidal_id': 1,
          'value': 'INDIFFERENT',
          'state': 'visible',
        },
      ]);
      expect(radio.currentRating!.eventId, event);
      expect(radio.currentRating!.tidalState, 'pending');
    },
  );

  test(
    'Tidal success is shown even when the YouTube outcome is uncertain',
    () async {
      fixture.youtubeUncertain = true;
      await radio.rate('LIKE');
      expect(radio.currentRating!.state, 'uncertain');
      expect(radio.currentRating!.tidalState, 'visible');
      expect(radio.currentRating!.label, contains('check YouTube Music'));
      expect(radio.currentRating!.label, contains('Liked on Tidal'));
      expect(radio.currentRating!.uncertain, true);
      await radio.sync();
      expect(fixture.writes.length, 1);
    },
  );

  test(
    'existing server ratings restore the selected song across occurrences',
    () {
      radio.mergeRatings([
        {
          'id': 'existing',
          'kind': 'rating:existing',
          'video_id': 'song',
          'value': 'LIKE',
          'state': 'visible',
          'created': '2026-11-03T00:00:00Z',
        },
      ]);
      expect(radio.currentRating!.value, 'LIKE');
      radio.entries.add(QueueEntry(radio.current!.song, tidal: {'id': 1}));
      radio.currentIndex = 1;
      expect(radio.currentRating!.value, 'LIKE');
      radio.mergeRatings([
        {
          'id': 'old',
          'kind': 'rating:old',
          'video_id': 'song',
          'value': 'DISLIKE',
          'state': 'submitted',
          'created': '2026-11-02T00:00:00Z',
        },
      ]);
      expect(radio.currentRating!.value, 'LIKE');
    },
  );

  test(
    'disk failure rolls back the selection and never sends a rating',
    () async {
      final blocker = File('${temporary.path}/blocked');
      await blocker.writeAsString('not a directory');
      final broken = RadioController(
        RadioDisk(File('${blocker.path}/state.json')),
      );
      final brokenFixture = RatingFixture(broken);
      await broken.rate('LIKE');
      expect(broken.currentRating, isNull);
      expect(broken.error, contains('Could not save your rating'));
      expect(brokenFixture.writes, isEmpty);
      // Consume the expected disk-write failure retained by the serializer.
      await broken.disk.settled.catchError((Object _) {});
      broken.api!.close();
      broken.dispose();
    },
  );

  testWidgets('rating buttons visibly select and clear on a second click', (
    tester,
  ) async {
    radio.api!.close();
    radio.dispose();
    radio = RadioController(MemoryDisk());
    fixture = RatingFixture(radio);
    tester.view.physicalSize = const Size(1360, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Finder button(String tooltip) => find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == tooltip,
    );
    await tester.pumpWidget(RadioApp(radio: radio));
    await tester.tap(button('Like on YouTube Music and Tidal'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(button('Remove like from both services'))
          .isSelected,
      true,
    );
    expect(find.text('Liked on YouTube Music\nLiked on Tidal'), findsOneWidget);
    await tester.tap(button('Remove like from both services'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(button('Like on YouTube Music and Tidal'))
          .isSelected,
      false,
    );
    await tester.tap(button('Dislike on YouTube Music'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(button('Remove dislike')).isSelected,
      true,
    );
    expect(find.text('Dislike sent to YouTube Music'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
