import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_radio/api.dart';
import 'package:personal_radio/models.dart';
import 'package:personal_radio/radio_controller.dart';

import 'support/player_fixture.dart';

void main() {
  late RadioController radio;
  late FakePlayer player;
  var now = Duration.zero;
  var fail = false;
  var status = 503;
  var calls = 0;
  Completer<http.Response>? pending;
  setUp(() async {
    now = Duration.zero;
    fail = false;
    status = 503;
    calls = 0;
    pending = null;
    player = FakePlayer();
    radio = RadioController(MemoryDisk(), leaseNow: () => now)
      ..connected = true
      ..player = player
      ..mode = 'station'
      ..nextCursor = 'same-context'
      ..position = const Duration(seconds: 22)
      ..entries = [QueueEntry(song('current'))]
      ..currentIndex = 0
      ..playing = true;
    radio.api = RadioApi(
      'http://127.0.0.1:8765',
      'test',
      radio.deviceId,
      client: MockClient((request) async {
        expect(request.url.path, '/api/device/lease');
        calls++;
        if (pending != null) return pending!.future;
        return http.Response(
          jsonEncode(
            fail
                ? {'detail': 'Temporary outage'}
                : {'active': true, 'lease_seconds': 25},
          ),
          fail ? status : 200,
        );
      }),
    );
    await radio.acquire();
  });
  tearDown(() {
    radio.api?.close();
    radio.dispose();
  });

  test(
    'brief heartbeat failure keeps playback, occurrence, position and outbox',
    () async {
      final original = radio.snapshot();
      fail = true;
      now = const Duration(seconds: 6);
      await radio.maintainPlaybackLease();
      expect(radio.playing, true);
      expect(radio.hasLease, true);
      expect(radio.snapshot(), original);
      fail = false;
      now = const Duration(seconds: 12);
      await radio.maintainPlaybackLease();
      now = const Duration(seconds: 25);
      await radio.maintainPlaybackLease();
      expect(radio.playing, true);
      expect(calls, 4);
    },
  );

  for (final code in [401, 403, 409]) {
    test(
      'authorization or takeover $code pauses immediately within lease',
      () async {
        fail = true;
        status = code;
        now = const Duration(seconds: 6);
        await radio.maintainPlaybackLease();
        expect(radio.playing, false);
        expect(radio.hasLease, false);
        expect(radio.position.inSeconds, 22);
      },
    );
  }

  test(
    'overlapping timer ticks do not stack heartbeats and expiry still pauses',
    () async {
      pending = Completer<http.Response>();
      now = const Duration(seconds: 6);
      final first = radio.maintainPlaybackLease();
      await Future<void>.delayed(Duration.zero);
      now = const Duration(seconds: 12);
      await radio.maintainPlaybackLease();
      expect(calls, 2);
      now = const Duration(seconds: 20);
      await radio.maintainPlaybackLease();
      expect(radio.playing, false);
      expect(radio.hasLease, false);
      expect(calls, 2);
      pending!.complete(http.Response('{"detail":"Unavailable"}', 503));
      await first;
      expect(radio.hasLease, false);
      expect(radio.outbox, isEmpty);
    },
  );
}
