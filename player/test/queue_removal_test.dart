import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_radio/app.dart';
import 'package:personal_radio/models.dart';

import 'support/player_fixture.dart';

void main() {
  late PlayerFixture f;
  setUp(() => f = PlayerFixture());
  tearDown(() => f.dispose());

  for (final mode in ['queue', 'autoplay', 'radio', 'station']) {
    test(
      '$mode removal targets an occurrence and preserves listening and context',
      () async {
        final r = f.radio;
        r.mode = mode;
        r.nextCursor = mode == 'queue' ? null : 'saved-cursor';
        r.queueTitle = 'Saved context';
        r.entries = [
          'same',
          'current',
          'same',
          'same',
        ].map((id) => QueueEntry(song(id))).toList();
        r.currentIndex = 1;
        r.playing = true;
        r.position = const Duration(seconds: 42);
        final ids = r.entries.map((e) => e.occurrenceId).toList();
        r.outbox = [
          {
            'id': 'durable-event',
            'body': {'occurrence_id': ids[0], 'seconds': 12},
          },
        ];
        expect(await r.removeOccurrence(ids[2]), true);
        expect(await r.removeOccurrence(ids[0]), true);
        expect(await r.removeOccurrence(ids[2]), false);
        expect(r.entries.map((e) => e.occurrenceId), [ids[1], ids[3]]);
        expect(r.current!.occurrenceId, ids[1]);
        expect(r.currentIndex, 0);
        expect(r.position.inSeconds, 42);
        expect(r.playing, true);
        expect(r.mode, mode);
        expect(r.queueTitle, 'Saved context');
        expect(r.nextCursor, mode == 'queue' ? null : 'saved-cursor');
        expect(f.requests, isEmpty);
        final saved = await r.disk.load();
        expect(saved['entries'].map((e) => e['id']), [ids[1], ids[3]]);
        expect(saved['outbox'].single['id'], 'durable-event');
        expect(saved['index'], 0);
      },
    );
  }

  test(
    'removing current skips without completion or rating; removing last stops',
    () async {
      final r = f.radio;
      await r.playSongs([song('one'), song('two')]);
      await r.prefetch();
      final first = r.current!.occurrenceId;
      final next = r.entries[1].occurrenceId;
      f.player.onStop = () => r.advance(natural: true);
      r.outbox = [
        {
          'id': 'heard',
          'body': {'occurrence_id': first, 'seconds': 8},
        },
      ];
      expect(await r.removeOccurrence(first), true);
      expect(r.current!.occurrenceId, next);
      expect(f.player.opened.length, 2);
      expect(r.outbox.single['id'], 'heard');
      expect(
        f.requests.any(
          (q) => q.url.path == '/api/events' || q.url.path == '/api/ratings',
        ),
        false,
      );
      expect(await r.removeOccurrence(next), true);
      expect(r.current, isNull);
      expect(r.entries, isEmpty);
      expect(r.position, Duration.zero);
      expect(r.duration, Duration.zero);
      expect(r.playing, false);
      expect(f.player.state.playing, false);
      expect(r.quality, isNull);
      final saved = await r.disk.load();
      expect(saved['entries'], isEmpty);
      expect(saved['outbox'].single['id'], 'heard');
    },
  );

  for (final offline in [false, true]) {
    test(
      'removing the final current row preserves history without replay (offline=$offline)',
      () async {
        final r = f.radio;
        await r.playSongs([song('old'), song('last')]);
        await r.prefetch();
        await r.advance();
        final oldId = r.entries.first.occurrenceId;
        if (offline) r.connected = false;
        await r.removeOccurrence(r.current!.occurrenceId);
        expect(r.current, isNull);
        expect(r.currentIndex, r.entries.length);
        r.connected = true;
        final opens = f.player.opened.length;
        final created = f.requests
            .where((q) => q.url.path == '/api/occurrences')
            .length;
        await r.play();
        expect(f.player.opened.length, opens);
        expect(
          f.requests.where((q) => q.url.path == '/api/occurrences').length,
          created,
        );
        expect(r.entries.single.occurrenceId, oldId);
        expect((await r.disk.load())['index'], r.entries.length);
        await r.enqueue([song('new')]);
        final nextId = r.entries.last.occurrenceId;
        await r.play();
        expect(r.current!.occurrenceId, nextId);
        expect(r.current!.song.id, 'new');
        expect(r.outbox, isEmpty);
      },
    );
  }

  test(
    'offline removal of current selects the next row without playing',
    () async {
      final r = f.radio;
      r.connected = false;
      r.entries = [
        'before',
        'current',
        'next',
      ].map((id) => QueueEntry(song(id))).toList();
      r.currentIndex = 1;
      await r.removeOccurrence(r.current!.occurrenceId);
      expect(r.current!.song.id, 'next');
      expect(r.playing, false);
      expect(f.requests, isEmpty);
    },
  );

  testWidgets('queue long-press removes the selected occurrence by ID', (
    tester,
  ) async {
    final r = f.radio;
    await r.enqueue([song('one'), song('two')]);
    await tester.pumpWidget(RadioApp(radio: r));
    await tester.tap(find.text('Queue').last);
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Song two'));
    await tester.pumpAndSettle();
    expect(find.text('Remove from queue'), findsOneWidget);
    await tester.tap(find.text('Remove from queue'));
    await tester.pumpAndSettle();
    expect(r.entries.single.song.id, 'one');
    expect(f.requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  test('removal preserves a recommendation page already in flight', () async {
    final r = f.radio;
    r.entries = [
      'current',
      'remove',
      'keep',
    ].map((id) => QueueEntry(song(id))).toList();
    r.currentIndex = 0;
    r.nextCursor = 'page-two';
    final response = Completer<Map<String, dynamic>>();
    final started = Completer<void>();
    f.catalog = (q) {
      expect(jsonDecode(q.body), {'cursor': 'page-two'});
      started.complete();
      return response.future;
    };
    final pending = r.prefetch();
    await started.future;
    await r.removeOccurrence(r.entries[1].occurrenceId);
    response.complete({
      'tracks': [song('new').source],
      'next_cursor': 'page-three',
    });
    await pending;
    expect(r.entries.map((e) => e.song.id), ['current', 'keep', 'new']);
    expect(r.nextCursor, 'page-three');
    expect(r.outbox, isEmpty);
  });

  testWidgets(
    'queue offers a remove button and removes only the chosen duplicate',
    (tester) async {
      final r = f.radio;
      await r.enqueue([song('same'), song('same')]);
      final remaining = r.entries.first.occurrenceId;
      await tester.pumpWidget(RadioApp(radio: r));
      await tester.tap(find.text('Queue').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove from queue').last);
      await tester.pumpAndSettle();
      expect(r.entries.single.occurrenceId, remaining);
      expect(find.text('Song same'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('right-to-left swipe removes a queue row; the reverse keeps it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await f.radio.enqueue([song('one'), song('two')]);
    await tester.pumpWidget(RadioApp(radio: f.radio));
    await tester.tap(find.text('Queue').last);
    await tester.pumpAndSettle();
    await tester.drag(find.text('Song one'), const Offset(350, 0));
    await tester.pumpAndSettle();
    expect(f.radio.entries.length, 2);
    await tester.drag(find.text('Song one'), const Offset(-350, 0));
    await tester.pumpAndSettle();
    expect(f.radio.entries.single.song.id, 'two');
    expect(find.text('Song one'), findsNothing);
    expect(f.requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
