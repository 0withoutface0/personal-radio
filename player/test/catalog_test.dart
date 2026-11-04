import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  test('direct album play uses finite queue, selected index and fresh persisted occurrences', () async {
    final r = f.radio;
    r.mode = 'station';
    r.nextCursor = 'old-station-cursor';
    final old = QueueEntry(song('old'));
    r.entries = [old];
    r.outbox = [
      {
        'path': '/api/events',
        'body': {'id': 'existing-event'},
      },
    ];
    await r.playSongs(
      [song('one'), song('two'), song('three')],
      startIndex: 1,
      title: 'Album',
    );
    expect(r.error, isNull);
    expect(r.current!.song.id, 'two');
    expect(r.mode, 'queue');
    expect(r.nextCursor, isNull);
    expect(r.queueTitle, 'Album');
    expect(r.entries.map((e) => e.occurrenceId).toSet().length, 3);
    expect(r.entries.every((e) => e.occurrenceId != old.occurrenceId), true);
    expect(r.outbox.single['body']['id'], 'existing-event');
    final firstPlay = r.current!.occurrenceId;
    expect(f.player.opened.single.uri, 'http://127.0.0.1:8765/fake.flac');
    expect(f.player.opened.single.httpHeaders!['Authorization'], 'Bearer test');
    expect(f.requests.any((q) => q.url.path == '/api/queues'), false);
    await r.prefetch();
    await r.playSongs([song('two')]);
    expect(r.current!.occurrenceId, isNot(firstPlay));
    expect(f.requests.where((q) => q.url.path == '/api/occurrences').length, 2);
  });

  test(
    'unavailable album tracks skip visibly without matching or reporting them',
    () async {
      await f.radio.playSongs([song('missing', available: false), song('two')]);
      expect(f.radio.entries.first.reason, 'Unavailable on YouTube Music');
      expect(f.radio.current!.song.id, 'two');
      final matches = f.requests.where((q) => q.url.path == '/api/match');
      expect(matches.length, 1);
      expect(jsonDecode(matches.single.body)['video_id'], 'two');
      expect(f.radio.outbox, isEmpty);
    },
  );

  test(
    'late searches cannot overwrite a newer kind or clear its loading state',
    () async {
      final first = Completer<Map<String, dynamic>>();
      final second = Completer<Map<String, dynamic>>();
      f.catalog = (request) => request.url.queryParameters['kind'] == 'songs'
          ? first.future
          : second.future;
      final old = f.radio.search('song');
      final newer = f.radio.search('artist', kind: 'artists');
      first.complete({
        'items': [song('old').source],
      });
      await old;
      expect(f.radio.searching, true);
      expect(f.radio.results, isEmpty);
      second.complete({
        'items': [
          {'id': 'UC1', 'title': 'Artist'},
        ],
      });
      await newer;
      expect(f.radio.searchKind, 'artists');
      expect(f.radio.catalogResults.single['id'], 'UC1');
      expect(f.radio.searching, false);
      expect(f.requests.every((q) => q.method == 'GET'), true);
    },
  );

  for (final size in [const Size(390, 844), const Size(1360, 850)]) {
    testWidgets(
      'now playing opens its album and Ctrl+K returns to search at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        f.radio.entries = [
          QueueEntry(song('current'), tidal: {'id': 123}),
        ];
        f.radio.currentIndex = 0;
        f.catalog = (_) async => {
          'id': 'MPRE1',
          'title': 'Album',
          'tracks': [song('one').source],
        };
        await tester.pumpWidget(RadioApp(radio: f.radio));
        if (size.width < 1000) {
          await tester.tap(find.text('Song current'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('Browse this song'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('View album'));
        await tester.pumpAndSettle();
        expect(find.text('Play album'), findsOneWidget);
        expect(find.text('Song one'), findsOneWidget);
        expect(f.requests.every((q) => q.method == 'GET'), true);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          true,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'browse artist releases, album tracks, back and direct playback at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        f.catalog = (q) async => switch (q.url.path) {
          '/api/catalog/search' => {
            'items': [
              {'id': 'UC1', 'title': 'Artist'},
            ],
          },
          '/api/catalog/artists/UC1' => {
            'id': 'UC1',
            'title': 'Artist',
            'songs': [song('top').source],
            'releases': {'albums': [], 'singles': []},
          },
          '/api/catalog/artists/UC1/releases' => {
            'items': [
              {
                'id': 'MPRE1',
                'title': 'A long album name with enough words to test a small screen',
              },
            ],
            'limit': 100,
            'has_more': false,
          },
          '/api/catalog/albums/MPRE1' => {
            'id': 'MPRE1',
            'title': 'Album',
            'tracks': [song('one').source, song('two').source],
          },
          _ => throw StateError('Unexpected catalog route ${q.url}'),
        };
        await tester.pumpWidget(RadioApp(radio: f.radio));
        await tester.enterText(find.byType(TextField), 'Artist');
        await tester.tap(find.widgetWithText(ChoiceChip, 'Artists'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Artist').last);
        await tester.pumpAndSettle();
        expect(find.text('Song top'), findsOneWidget);
        await tester.tap(find.widgetWithText(ChoiceChip, 'Albums'));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('A long album name'));
        await tester.pumpAndSettle();
        expect(find.text('Song one'), findsOneWidget);
        expect(find.text('Song two'), findsOneWidget);
        expect(f.requests.every((q) => q.method == 'GET'), true);
        expect(f.radio.entries, isEmpty);
        await tester.tap(find.byTooltip('Back to browsing'));
        await tester.pumpAndSettle();
        expect(find.textContaining('A long album name'), findsOneWidget);
        await tester.tap(find.textContaining('A long album name'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Play song').last);
        await tester.pumpAndSettle();
        expect(f.radio.current!.song.id, 'two');
        expect(f.radio.entries.length, 2);
        expect(f.radio.queueTitle, 'Album');
        expect(f.radio.outbox, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
