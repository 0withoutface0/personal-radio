import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_radio/api.dart';
import 'package:personal_radio/app.dart';
import 'package:personal_radio/models.dart';

import 'support/player_fixture.dart';

Map<String, dynamic> card(String id) => {
  'kind': 'song',
  'title': 'Shortcut $id',
  'play_id': 'play-$id',
  'song': {...song(id).source, 'title': 'Shortcut $id'},
};
Map<String, dynamic> feed() => {
  'speed_dial': {
    'items': [
      card('speed'),
      {'kind': 'artist', 'id': 'UC1', 'title': 'Artist shortcut'},
      {'kind': 'album', 'id': 'MPRE1', 'title': 'Album shortcut'},
      {
        'kind': 'playlist',
        'id': 'PL1',
        'title': 'Playlist shortcut',
        'play_id': 'play-playlist',
      },
      for (var i = 4; i < 12; i++) card('speed$i'),
    ],
  },
  'quick_picks': {
    'play_all_id': 'all-picks',
    'items': [for (var i = 0; i < 6; i++) card('pick$i')],
  },
};

void main() {
  late PlayerFixture f;
  setUp(() => f = PlayerFixture());
  tearDown(() => f.dispose());

  test(
    'home reads and failed refresh preserve queue, cursor and outbox',
    () async {
      final r = f.radio;
      r.entries = [QueueEntry(song('current'))];
      r.currentIndex = 0;
      r.nextCursor = 'context';
      r.position = const Duration(seconds: 19);
      r.outbox = [
        {
          'id': 'pending',
          'body': {'seconds': 2},
        },
      ];
      f.catalog = (q) async {
        expect(q.method, 'GET');
        expect(q.url.path, '/api/home');
        return feed();
      };
      await r.loadHome();
      expect(r.home!['speed_dial']['items'].length, 12);
      expect(r.homeError, isNull);
      final previous = r.home;
      f.catalog = (q) async {
        expect(q.url.query, 'refresh=true');
        throw ApiFailure(503, 'YouTube requests sign-in. Reconnect.');
      };
      await r.loadHome(refresh: true);
      expect(r.home, same(previous));
      expect(r.homeError, contains('sign-in'));
      expect(r.homeLoading, false);
      expect(r.current!.song.id, 'current');
      expect(r.position.inSeconds, 19);
      expect(r.nextCursor, 'context');
      expect(r.outbox.single['id'], 'pending');
      expect(f.requests.every((q) => q.method == 'GET'), true);
    },
  );

  test('late home response cannot overwrite a newer refresh', () async {
    final pending = Completer<Map<String, dynamic>>();
    f.catalog = (q) => q.url.hasQuery
        ? Future.value({
            'speed_dial': {'items': []},
          })
        : pending.future;
    final old = f.radio.loadHome();
    await Future<void>.delayed(Duration.zero);
    await f.radio.loadHome(refresh: true);
    pending.complete(feed());
    await old;
    expect(f.radio.home!['speed_dial']['items'], isEmpty);
    expect(f.radio.homeLoading, false);
  });

  for (final size in [const Size(390, 844), const Size(1360, 850)]) {
    testWidgets('home grid, catalog shortcuts and paging fit $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      f.radio.home = feed();
      f.catalog = (q) async => {
        'id': q.url.path.contains('artists') ? 'UC1' : 'MPRE1',
        'title': 'Opened catalog',
        'songs': [],
        'tracks': [],
        'releases': {'albums': [], 'singles': []},
      };
      await tester.pumpWidget(RadioApp(radio: f.radio));
      expect(find.text('Speed dial'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.tap(find.text('Artist shortcut'));
      await tester.pumpAndSettle();
      expect(f.requests.last.url.path, '/api/catalog/artists/UC1');
      expect(find.text('Opened catalog'), findsOneWidget);
      await tester.tap(find.byTooltip('Back to browsing'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Album shortcut'));
      await tester.pumpAndSettle();
      expect(f.requests.last.url.path, '/api/catalog/albums/MPRE1');
      await tester.tap(find.byTooltip('Back to browsing'));
      await tester.pumpAndSettle();
      if (size.width > 1000) {
        await tester.tap(find.byTooltip('Next Speed dial page'));
      } else {
        await tester.drag(find.byType(PageView), const Offset(-650, 0));
      }
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('Shortcut speed11'), findsOneWidget);
      expect(f.radio.entries, isEmpty);
      expect(f.requests.every((q) => q.method == 'GET'), true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final selection in ['speed', 'playlist', 'all', 'pick0']) {
    testWidgets(
      '$selection uses the returned server target and persisted queue order',
      (tester) async {
        tester.view.physicalSize = const Size(1360, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        f.radio.home = feed();
        f.catalog = (q) async {
          expect(q.url.path, '/api/home/play');
          expect(jsonDecode(q.body), {
            'selection_id': selection == 'all'
                ? 'all-picks'
                : 'play-$selection',
          });
          return {
            'mode': selection == 'all' || selection == 'pick0'
                ? 'radio'
                : 'autoplay',
            'title': 'Provider title',
            'next_cursor': null,
            'tracks': [
              song('returned-first').source,
              song('returned-next').source,
            ],
          };
        };
        await tester.pumpWidget(RadioApp(radio: f.radio));
        if (selection == 'all' || selection == 'pick0') {
          final home = find.byKey(const PageStorageKey('youtube-home'));
          await tester.scrollUntilVisible(
            find.text(selection == 'all' ? 'Play all' : 'Shortcut pick0'),
            150,
            scrollable: find
                .descendant(of: home, matching: find.byType(Scrollable))
                .first,
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(selection == 'all' ? 'Play all' : 'Shortcut pick0'),
          );
        } else {
          await tester.tap(
            find.text(
              selection == 'speed' ? 'Shortcut speed' : 'Playlist shortcut',
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(f.radio.entries.map((e) => e.song.id), [
          'returned-first',
          'returned-next',
        ]);
        expect(f.radio.queueTitle, 'Provider title');
        expect(f.radio.current!.song.id, 'returned-first');
        expect(f.radio.outbox, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('home song long-press enqueues without starting a stream', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    f.radio.home = feed();
    await tester.pumpWidget(RadioApp(radio: f.radio));
    await tester.longPress(find.text('Shortcut speed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();
    expect(f.radio.entries.single.song.id, 'speed');
    expect(f.requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('For you returns from search without an empty query request', (
    tester,
  ) async {
    f.radio.home = feed();
    f.radio.results = [song('search-result')];
    await tester.pumpWidget(RadioApp(radio: f.radio));
    expect(find.text('Song search-result'), findsOneWidget);
    await tester.tap(find.text('For you'));
    await tester.pumpAndSettle();
    expect(find.text('Speed dial'), findsOneWidget);
    expect(f.radio.results, isEmpty);
    expect(f.requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
