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
  Map<String, dynamic> state = {};
  MemoryDisk() : super(File('unused-match-widget-state.json'));
  @override
  Future<void> save(Map<String, dynamic> value) async {
    state = Map<String, dynamic>.from(jsonDecode(jsonEncode(value)));
  }

  @override
  Future<Map<String, dynamic>> load() async => state;
  @override
  Future<void> get settled => Future.value();
}

void main() {
  late Directory temporary;
  late RadioController radio;
  final candidate = {
    'track': {
      'id': 123,
      'title': 'Song',
      'artists': ['Artist'],
      'album': 'Single',
      'duration': 180,
      'explicit': true,
    },
    'score': .95,
    'rejection': null,
  };

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('radio-matching-');
    radio = RadioController(RadioDisk(File('${temporary.path}/state.json')));
    radio.connected = true;
  });
  tearDown(() async {
    await radio.disk.settled;
    radio.api?.close();
    radio.dispose();
    await temporary.delete(recursive: true);
  });

  QueueEntry skipped() => QueueEntry(
    Song({
      'video_id': 'original-video',
      'title': 'Song (Official Video)',
      'artists': ['Artist'],
      'duration': 199,
      'video_type': 'MUSIC_VIDEO_TYPE_OMV',
      'counterpart': {'video_id': 'audio', 'duration': 180},
    }),
    status: 'skipped',
    reason: 'Old match failed',
  );

  void connect(Future<http.Response> Function(http.Request) handle) {
    radio.api = RadioApi(
      'http://127.0.0.1:8765',
      'test',
      radio.deviceId,
      client: MockClient(handle),
    );
  }

  test(
    'retry preserves occurrences, reporting events, queue position and context',
    () async {
      final entry = skipped();
      final occurrence = entry.occurrenceId;
      radio.entries = [
        QueueEntry(
          Song({'video_id': 'current'}),
          status: 'playing',
          tidal: {'id': 99},
        ),
        entry,
      ];
      radio.currentIndex = 0;
      radio.position = const Duration(seconds: 22);
      radio.nextCursor = 'existing-cursor';
      radio.outbox = [
        {
          'path': '/api/events',
          'body': {'id': 'event'},
        },
      ];
      connect((request) async {
        expect(request.url.path, '/api/match');
        final body = jsonDecode(request.body);
        expect(body['video_id'], 'original-video');
        expect(body['counterpart']['video_id'], 'audio');
        return http.Response(
          jsonEncode({'status': 'matched', 'track': candidate['track']}),
          200,
        );
      });
      await radio.retrySkippedMatches();
      expect(entry.status, 'matched');
      expect(entry.occurrenceId, occurrence);
      expect(entry.song.id, 'original-video');
      expect(radio.currentIndex, 0);
      expect(radio.position.inSeconds, 22);
      expect(radio.nextCursor, 'existing-cursor');
      expect(radio.outbox.single['body']['id'], 'event');
      expect((await radio.disk.load())['entries'][1]['id'], occurrence);
    },
  );

  test(
    'ambiguous candidates persist across restarts for deliberate correction',
    () async {
      final entry = skipped();
      radio.entries = [entry];
      connect(
        (request) async => http.Response(
          jsonEncode({
            'status': 'skipped',
            'reason': 'Ambiguous recordings',
            'candidates': [candidate],
          }),
          200,
        ),
      );
      await radio.retrySkippedMatches();
      final saved = QueueEntry.fromJson(
        (await radio.disk.load())['entries'][0],
      );
      expect(saved.status, 'skipped');
      expect(saved.reason, 'Ambiguous recordings');
      expect(saved.candidates.single['track']['id'], 123);
      expect(saved.occurrenceId, entry.occurrenceId);
    },
  );

  test(
    'failed retry keeps the old skipped state and can be tried again',
    () async {
      final entry = skipped();
      radio.entries = [entry];
      connect((request) async => throw http.ClientException('offline'));
      await radio.retrySkippedMatches();
      expect(entry.status, 'skipped');
      expect(entry.reason, 'Old match failed');
      expect(radio.retryingMatches, false);
      expect(entry.tidal, isNull);
    },
  );

  testWidgets(
    'review a candidate and save its correction without starting playback',
    (tester) async {
      radio.dispose();
      radio = RadioController(MemoryDisk())..connected = true;
      tester.view.physicalSize = const Size(1360, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final entry = skipped()..candidates = [candidate];
      radio.entries = [entry];
      final writes = <String>[];
      connect((request) async {
        writes.add(request.url.path);
        expect(request.method, 'PUT');
        expect(jsonDecode(request.body), {
          'video_id': 'original-video',
          'tidal_id': 123,
        });
        return http.Response(jsonEncode({'track': candidate['track']}), 200);
      });
      await tester.pumpWidget(RadioApp(radio: radio));
      await tester.tap(find.text('Queue').last);
      await tester.pumpAndSettle();
      expect(find.text('Retry skipped matches'), findsOneWidget);
      await tester.tap(find.byTooltip('Save a recording correction'));
      await tester.pumpAndSettle();
      expect(find.text('Song'), findsOneWidget);
      expect(find.textContaining('Single · 3:00 · Explicit'), findsOneWidget);
      await tester.tap(find.byTooltip('Use this recording'));
      await tester.pumpAndSettle();
      expect(entry.status, 'matched');
      expect(entry.tidal!['id'], 123);
      expect(radio.currentIndex, -1);
      expect(writes, ['/api/corrections']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
