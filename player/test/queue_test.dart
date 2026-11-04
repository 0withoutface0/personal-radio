import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_radio/app.dart';
import 'package:personal_radio/models.dart';

import 'support/player_fixture.dart';

void main() {
  late PlayerFixture f;
  setUp(() {
    f = PlayerFixture();
  });
  tearDown(() {
    f.dispose();
  });

  for (final mode in ['autoplay', 'radio', 'station']) {
    test(
      '$mode insertions preserve cursor, provider order, playback and events across restore',
      () async {
        final r = f.radio;
        r.mode = mode;
        r.queueTitle = 'Original station';
        r.nextCursor = 'saved-context';
        r.entries = [
          'current',
          'rec1',
          'rec2',
        ].map((id) => QueueEntry(song(id))).toList();
        r.currentIndex = 0;
        r.position = const Duration(seconds: 22);
        r.playing = true;
        final originalIds = r.entries.map((e) => e.occurrenceId).toList();
        r.outbox = [
          {
            'path': '/api/ratings',
            'body': {'id': 'saved-rating'},
          },
        ];
        expect(await r.enqueue([song('tail')]), 1);
        expect(
          await r.enqueue([song('album1'), song('album2')], next: true),
          2,
        );
        expect(await r.enqueue([song('newest')], next: true), 1);
        expect(r.entries.map((e) => e.song.id), [
          'current',
          'newest',
          'album1',
          'album2',
          'rec1',
          'rec2',
          'tail',
        ]);
        expect(r.mode, mode);
        expect(r.nextCursor, 'saved-context');
        expect(r.queueTitle, 'Original station');
        expect(r.current!.occurrenceId, originalIds.first);
        expect(r.position.inSeconds, 22);
        expect(r.playing, true);
        expect(f.requests, isEmpty);
        final saved = await r.disk.load();
        final restored = (saved['entries'] as List)
            .map((j) => QueueEntry.fromJson(Map<String, dynamic>.from(j)))
            .toList();
        expect(
          restored.map((e) => e.occurrenceId),
          r.entries.map((e) => e.occurrenceId),
        );
        expect(
          restored.where((e) => !e.addedByUser).map((e) => e.occurrenceId),
          originalIds,
        );
        expect(saved['cursor'], 'saved-context');
        expect(saved['outbox'][0]['body']['id'], 'saved-rating');
      },
    );
  }

  test('adding to an empty queue stays stopped and a later play uses the saved occurrence', () async {
    final r = f.radio;
    await r.enqueue([song('one'), song('one')]);
    expect(r.current, isNull);
    expect(r.mode, 'queue');
    expect(r.entries[0].occurrenceId, isNot(r.entries[1].occurrenceId));
    expect(f.requests, isEmpty);
    final id = r.entries.first.occurrenceId;
    await r.play();
    expect(r.current!.occurrenceId, id);
    await r.prefetch();
    await r.pause();
    await r.play();
    final opens = f.requests.where((q) => q.url.path == '/api/occurrences');
    expect(opens.length, 1);
    expect(jsonDecode(opens.single.body)['id'], id);
    expect(r.outbox, isEmpty);
  });

  test('in-flight recommendation batch follows inserted tracks without losing context', () async {
    final r = f.radio;
    r.mode = 'autoplay';
    r.nextCursor = 'page-two';
    r.entries = ['current', 'rec1'].map((id) => QueueEntry(song(id))).toList();
    r.currentIndex = 0;
    final pending = Completer<Map<String, dynamic>>();
    final started = Completer<void>();
    f.catalog = (q) {
      expect(q.url.path, '/api/queues');
      expect(jsonDecode(q.body), {'cursor': 'page-two'});
      started.complete();
      return pending.future;
    };
    final fetching = r.prefetch();
    await started.future;
    await r.enqueue([song('next1'), song('next2')], next: true);
    await r.enqueue([song('tail')]);
    pending.complete({
      'tracks': [song('rec2').source, song('rec3').source],
      'next_cursor': 'page-three',
    });
    await fetching;
    expect(r.entries.map((e) => e.song.id), [
      'current',
      'next1',
      'next2',
      'rec1',
      'tail',
      'rec2',
      'rec3',
    ]);
    expect(r.nextCursor, 'page-three');
    expect(r.mode, 'autoplay');
    expect(r.outbox, isEmpty);
    expect(f.requests.any((q) => q.url.path == '/api/occurrences'), false);
  });

  test(
    'starting direct playback discards an old radio page arriving late',
    () async {
      final r = f.radio;
      r.entries = [QueueEntry(song('old'))];
      r.currentIndex = 0;
      r.nextCursor = 'old-cursor';
      final pending = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      f.catalog = (_) {
        started.complete();
        return pending.future;
      };
      final fetching = r.prefetch();
      await started.future;
      await r.playSongs([song('direct')]);
      pending.complete({
        'tracks': [song('stale').source],
        'next_cursor': 'stale-cursor',
      });
      await fetching;
      expect(r.entries.map((e) => e.song.id), ['direct']);
      expect(r.nextCursor, isNull);
      expect(r.mode, 'queue');
    },
  );

  testWidgets('song actions enqueue without playback and expose Play queue', (
    tester,
  ) async {
    f.radio.results = [song('one')];
    await tester.pumpWidget(RadioApp(radio: f.radio));
    await tester.tap(find.byTooltip('Song actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();
    expect(find.text('Added 1 song to queue'), findsOneWidget);
    expect(f.radio.entries.single.song.id, 'one');
    expect(f.requests, isEmpty);
    await tester.tap(find.text('Queue').last);
    await tester.pumpAndSettle();
    expect(find.text('Play queue'), findsOneWidget);
    expect(find.textContaining('Added by you'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
