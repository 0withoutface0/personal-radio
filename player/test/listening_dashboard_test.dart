import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_radio/api.dart';
import 'package:personal_radio/app.dart';
import 'package:personal_radio/listening_range.dart';
import 'package:personal_radio/listening_view.dart';

import 'support/player_fixture.dart';

Map<String, dynamic> stats(Map<String, dynamic> request, {int seconds = 900}) {
  final boundaries = (request['boundaries'] as List).cast<String>();
  final track = {
    'title': 'Violet Skies',
    'artist': 'Night Signals',
    'plays': 4,
    'listened_seconds': seconds,
    'liked': true,
  };
  return {
    'first_played_at': DateTime(2024).toUtc().toIso8601String(),
    'totals': {
      'listened_seconds': seconds,
      'plays': 4,
      'songs': 1,
      'artists': 1,
    },
    'buckets': [
      for (var i = 0; i < boundaries.length - 1; i++)
        {
          'start': boundaries[i],
          'end': boundaries[i + 1],
          'listened_seconds': i == 0
              ? seconds - 180
              : i == 1
              ? 180
              : 0,
        },
    ],
    'top_songs': [track],
    'most_played': [track],
    'liked_songs': [track],
    'top_artists': [
      {'artist': 'Night Signals', 'plays': 4, 'listened_seconds': seconds},
    ],
  };
}

void main() {
  test(
    'calendar periods use leap dates, Mondays, and bounded lifetime buckets',
    () {
      final february = ListeningRange(
        ListeningPeriod.month,
        DateTime(2024, 2, 19),
      );
      expect(february.start, DateTime(2024, 2));
      expect(february.boundaries, hasLength(30));
      expect(february.step(1), DateTime(2024, 3));
      expect(february.step(-1), DateTime(2024, 1, 31));
      final week = ListeningRange(ListeningPeriod.week, DateTime(2024, 1, 1));
      expect(week.start, DateTime(2024, 1, 1));
      expect(week.boundaries, hasLength(8));
      final year = ListeningRange(ListeningPeriod.year, DateTime(2024, 12, 31));
      expect(year.boundaries, hasLength(13));
      expect(year.end, DateTime(2025));
      final recent = ListeningRange(
        ListeningPeriod.allTime,
        DateTime(2024, 2, 5),
        firstPlayed: DateTime(2024, 1, 30, 21),
      );
      expect(recent.bucket, ListeningBucket.day);
      expect(recent.boundaries.first, DateTime(2024, 1, 30));
      final lifetime = ListeningRange(
        ListeningPeriod.allTime,
        DateTime(2024, 2, 5),
        firstPlayed: DateTime(1980),
      );
      expect(lifetime.boundaries.length, lessThanOrEqualTo(33));
      expect(lifetime.boundaries.last, DateTime(2025));
      expect(lifetime.toRequest()['all_time'], true);
    },
  );

  for (final size in [const Size(390, 844), const Size(1360, 850)]) {
    testWidgets('Listening navigation, chart, and rankings fit $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = PlayerFixture();
      addTearDown(f.dispose);
      final requests = <Map<String, dynamic>>[];
      f.catalog = (request) async {
        if (request.url.path == '/api/report') return {'submissions': []};
        expect(request.url.path, '/api/listening');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requests.add(body);
        return stats(body);
      };
      await tester.pumpWidget(RadioApp(radio: f.radio));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Listening'));
      await tester.pumpAndSettle();
      expect(find.text('Listening activity'), findsOneWidget);
      expect(find.text('15 min'), findsOneWidget);
      expect(requests.single['boundaries'], hasLength(8));

      final bar = find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && (widget.message?.endsWith('· 3 min') ?? false),
      );
      final list = find
          .descendant(
            of: find.byType(ListeningView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(bar.hitTestable(), 130, scrollable: list);
      await tester.tap(bar.hitTestable());
      await tester.pumpAndSettle();
      expect(
        find.textContaining(RegExp(r'^(?!Peak).* · 3 min$')),
        findsOneWidget,
      );

      tester.state<ScrollableState>(list).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Month'));
      await tester.pumpAndSettle();
      expect(requests.last['boundaries'].length, inInclusiveRange(29, 32));
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      final before = DateTime.parse(requests.last['boundaries'].first);
      await tester.tap(find.byTooltip('Next month'));
      await tester.pumpAndSettle();
      expect(
        DateTime.parse(requests.last['boundaries'].first).isAfter(before),
        true,
      );
      await tester.tap(find.text('All time'));
      await tester.pumpAndSettle();
      expect(requests.last['all_time'], true);
      await tester.scrollUntilVisible(
        find.text('Liked').hitTestable(),
        260,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Liked'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Liked in Personal Radio'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        f.requests.every(
          (request) =>
              ['/api/listening', '/api/report'].contains(request.url.path),
        ),
        true,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('an older period response cannot replace a newer selection', (
    tester,
  ) async {
    final f = PlayerFixture();
    addTearDown(f.dispose);
    final old = Completer<void>();
    f.catalog = (request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if ((body['boundaries'] as List).length == 8) {
        await old.future;
        return stats(body);
      }
      return stats(body, seconds: 1800);
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ListeningView(radio: f.radio)),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Year'));
    await tester.pumpAndSettle();
    expect(find.text('30 min'), findsOneWidget);
    old.complete();
    await tester.pumpAndSettle();
    expect(find.text('30 min'), findsOneWidget);
    expect(find.text('15 min'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'old server retains listening totals and rankings with update guidance',
    (tester) async {
      final f = PlayerFixture();
      addTearDown(f.dispose);
      f.radio.report = {
        'totals': {'listened_seconds': 540, 'occurrences': 3},
        'top_songs': [
          {
            'title': 'Saved song',
            'artist': 'Saved artist',
            'listened_seconds': 540,
          },
        ],
      };
      f.beforeRequest = (_) async => throw ApiFailure(404, 'Not found');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ListeningView(radio: f.radio)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Update the radio server'), findsOneWidget);
      expect(find.text('9 min'), findsAtLeastNWidgets(1));
      expect(find.text('Saved song'), findsOneWidget);
      expect(find.text('Week'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
