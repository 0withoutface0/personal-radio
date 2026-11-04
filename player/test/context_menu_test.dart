import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_radio/app.dart';
import 'package:personal_radio/models.dart';
import 'package:personal_radio/song_actions.dart';

import 'support/player_fixture.dart';

void main() {
  late PlayerFixture f;
  setUp(() {
    f = PlayerFixture();
  });
  tearDown(() {
    f.dispose();
  });

  Future<void> rightClick(WidgetTester tester, Finder target) async {
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.down(tester.getCenter(target));
    await mouse.up();
    await tester.pumpAndSettle();
  }

  void desktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(1360, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'right-click chooses the clicked song and preserves current radio state',
    (tester) async {
      desktop(tester);
      final r = f.radio;
      r.entries = [
        'current',
        'recommendation',
      ].map((id) => QueueEntry(song(id))).toList();
      r.currentIndex = 0;
      r.position = const Duration(seconds: 22);
      r.nextCursor = 'original-radio-cursor';
      final original = r.current!.occurrenceId;
      r.results = [song('first'), song('second')];
      await tester.pumpWidget(RadioApp(radio: r));
      await rightClick(tester, find.text('Song second'));
      for (final label in [
        'Play next',
        'Add to queue',
        'Autoplay',
        'Start radio / mix',
        'View album',
        'View artist: Artist',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(f.requests, isEmpty);
      expect(r.entries.length, 2);
      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();
      expect(r.entries.map((e) => e.song.id), [
        'current',
        'second',
        'recommendation',
      ]);
      expect(r.current!.occurrenceId, original);
      expect(r.position.inSeconds, 22);
      expect(r.nextCursor, 'original-radio-cursor');
      expect(f.requests, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'right-clicking a play button opens options without firing play',
    (tester) async {
      f.radio.results = [song('one')];
      await tester.pumpWidget(RadioApp(radio: f.radio));
      await rightClick(tester, find.byTooltip('Play song'));
      expect(find.text('Add to queue'), findsOneWidget);
      expect(f.requests, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Add to queue'), findsNothing);
      expect(f.radio.entries, isEmpty);
      expect(f.requests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final kind in ['artists', 'albums']) {
    testWidgets(
      'right-click works on ${kind == 'artists' ? 'artist songs' : 'album tracks'}',
      (tester) async {
        f.radio.searchKind = kind;
        f.radio.catalogResults = [
          {'id': kind == 'artists' ? 'UC1' : 'MPRE1', 'title': 'Catalog item'},
        ];
        f.catalog = (_) async => {
          'id': kind == 'artists' ? 'UC1' : 'MPRE1',
          'title': 'Catalog item',
          'songs': [song('one').source],
          'tracks': [song('one').source],
          'releases': {'albums': [], 'singles': []},
        };
        await tester.pumpWidget(RadioApp(radio: f.radio));
        await tester.tap(find.text('Catalog item'));
        await tester.pumpAndSettle();
        final before = f.requests.length;
        await rightClick(tester, find.text('Song one'));
        await tester.tap(find.text('Add to queue'));
        await tester.pumpAndSettle();
        expect(f.radio.entries.single.song.id, 'one');
        expect(f.requests.length, before);
        expect(f.requests.every((q) => q.method == 'GET'), true);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'queue right-click can browse the targeted song without selecting playback',
    (tester) async {
      f.radio.entries = [QueueEntry(song('one'))];
      f.catalog = (q) async {
        expect(q.url.path, '/api/catalog/albums/MPRE1');
        return {
          'id': 'MPRE1',
          'title': 'Album',
          'tracks': [song('one').source],
        };
      };
      await tester.pumpWidget(RadioApp(radio: f.radio));
      await tester.tap(find.text('Queue').last);
      await tester.pumpAndSettle();
      await rightClick(tester, find.text('Song one'));
      await tester.tap(find.text('View album'));
      await tester.pumpAndSettle();
      expect(find.text('Play album'), findsOneWidget);
      expect(f.requests.single.method, 'GET');
      expect(f.radio.currentIndex, -1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final target in ['now playing', 'bottom player']) {
    testWidgets('$target right-click offers full song options', (tester) async {
      desktop(tester);
      f.radio.entries = [QueueEntry(song('current'))];
      f.radio.currentIndex = 0;
      await tester.pumpWidget(RadioApp(radio: f.radio));
      final titles = find.text('Song current');
      await rightClick(
        tester,
        target == 'now playing' ? titles.first : titles.last,
      );
      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.text('NOW PLAYING'), findsOneWidget);
      expect(f.requests, isEmpty);
      await tester.tap(find.text('Add to queue'));
      await tester.pumpAndSettle();
      expect(f.radio.entries.length, 2);
      expect(f.radio.entries.last.song.id, 'current');
      expect(f.requests, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  testWidgets('touch long-press uses the same actions', (tester) async {
    f.radio.results = [song('one')];
    await tester.pumpWidget(RadioApp(radio: f.radio));
    await tester.longPress(find.text('Song one'));
    await tester.pumpAndSettle();
    expect(find.text('Autoplay'), findsOneWidget);
    expect(f.requests, isEmpty);
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();
    expect(f.radio.entries.single.song.id, 'one');
    expect(f.requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'unavailable songs keep browsing but disable queue/play actions',
    (tester) async {
      f.radio.results = [song('missing', available: false)];
      await tester.pumpWidget(RadioApp(radio: f.radio));
      await rightClick(tester, find.text('Song missing'));
      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();
      expect(find.text('View album'), findsOneWidget);
      expect(f.radio.entries, isEmpty);
      expect(f.requests, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'pointer menu stays inside the viewport near the bottom-right edge',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: SongActions(
                radio: f.radio,
                song: song('one'),
                onBrowse: (_, _) {},
                builder: (_) => const SizedBox(
                  width: 100,
                  height: 60,
                  child: Text('Corner song'),
                ),
              ),
            ),
          ),
        ),
      );
      await rightClick(tester, find.text('Corner song'));
      final first = tester.getRect(find.text('Play next'));
      final last = tester.getRect(find.text('View artist: Artist'));
      final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(first.left, greaterThanOrEqualTo(0));
      expect(first.top, greaterThanOrEqualTo(0));
      expect(last.right, lessThanOrEqualTo(viewport.width));
      expect(last.bottom, lessThanOrEqualTo(viewport.height));
      expect(tester.takeException(), isNull);
      expect(f.requests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
