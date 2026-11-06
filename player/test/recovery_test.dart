import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/player_fixture.dart';

void main() {
  late PlayerFixture f;
  var now = Duration.zero;
  setUp(() async {
    now = Duration.zero;
    f = PlayerFixture(leaseNow: () => now);
    await f.radio.playSongs([song('one'), song('two')]);
    // Let the initial unawaited fixture prefetch/quality reads finish before
    // a test starts holding subsequent transport requests.
    await Future<void>.delayed(Duration.zero);
    await f.radio.prefetch();
    f.radio.position = const Duration(seconds: 22);
    f.radio.playing = true;
  });
  tearDown(() => f.dispose());

  test(
    'pause while a manual Play awaits lease confirmation cannot resume later',
    () async {
      await f.radio.pause();
      final started = Completer<void>();
      final release = Completer<void>();
      f.onLease = () async {
        started.complete();
        await release.future;
      };
      final play = f.radio.play();
      await started.future;
      await f.radio.pause();
      release.complete();
      await play;
      expect(f.player.state.playing, false);
    },
  );

  test(
    'pause while the next song is being matched cancels late playback',
    () async {
      f.radio.entries[1].tidal = null;
      f.radio.entries[1].status = 'pending';
      final started = Completer<void>();
      final release = Completer<void>();
      f.onMatch = () async {
        started.complete();
        await release.future;
      };
      final advance = f.radio.advance();
      await started.future;
      await f.radio.pause();
      release.complete();
      await advance;
      expect(f.player.state.playing, false);
      expect(f.player.opened.length, 1);
    },
  );

  test('lease outage suspends audio before expiry and recovery reacquires without takeover', () async {
    final id = f.radio.current!.occurrenceId;
    now = const Duration(seconds: 20);
    await f.radio.maintainPlaybackLease();
    expect(f.radio.playing, false);
    expect(f.radio.hasLease, false);
    await f.radio.checkPlaybackConnection();
    expect(f.player.state.playing, true);
    expect(f.radio.hasLease, true);
    expect(f.radio.current!.occurrenceId, id);
    expect(f.radio.position.inSeconds, 22);
  });

  test('silent stalled socket reopens same occurrence at saved position without activity', () async {
    final id = f.radio.current!.occurrenceId;
    now = const Duration(seconds: 11);
    await f.radio.checkPlaybackConnection();
    expect(f.player.opened.length, 1);
    now = const Duration(seconds: 13);
    await f.radio.checkPlaybackConnection();
    expect(f.player.opened.length, 2);
    expect(f.player.state.playing, true);
    expect(f.player.state.position.inSeconds, 22);
    expect(f.radio.current!.occurrenceId, id);
    expect(f.radio.currentIndex, 0);
    expect(f.radio.outbox, isEmpty);
    expect(
      f.requests.where(
        (q) => q.url.path == '/api/events' || q.url.path == '/api/ratings',
      ),
      isEmpty,
    );
  });

  test(
    'failed reopen retries with backoff after the connection returns',
    () async {
      var fails = true;
      f.player.onOpen = () async {
        if (fails) throw const SocketException('Fixture offline');
      };
      now = const Duration(seconds: 13);
      await f.radio.checkPlaybackConnection();
      expect(f.player.state.playing, false);
      await f.radio.checkPlaybackConnection();
      expect(f.player.opened.length, 2);
      fails = false;
      now = const Duration(seconds: 15);
      await f.radio.checkPlaybackConnection();
      expect(f.player.opened.length, 3);
      expect(f.player.state.playing, true);
      expect(f.radio.error, isNull);
      expect(f.radio.outbox, isEmpty);
    },
  );

  test(
    'pause cancels an in-flight reopen and late completion cannot resume',
    () async {
      final opened = Completer<void>();
      final release = Completer<void>();
      f.player.onOpen = () async {
        opened.complete();
        await release.future;
      };
      now = const Duration(seconds: 13);
      final recovery = f.radio.checkPlaybackConnection();
      await opened.future;
      await f.radio.pause();
      release.complete();
      await recovery;
      expect(f.player.state.playing, false);
      now = const Duration(seconds: 50);
      await f.radio.checkPlaybackConnection();
      expect(f.player.opened.length, 2);
    },
  );

  test(
    'three failed attempts stop automatically and explicit Play can reconnect',
    () async {
      f.player.onOpen = () async =>
          throw const SocketException('Fixture offline');
      final id = f.radio.current!.occurrenceId;
      for (final second in [13, 16, 21, 28]) {
        now = Duration(seconds: second);
        await f.radio.checkPlaybackConnection();
      }
      expect(f.player.opened.length, 4);
      expect(f.radio.playing, false);
      expect(f.radio.error, contains('Press play'));
      f.player.onOpen = null;
      await f.radio.play();
      expect(f.player.state.playing, true);
      expect(f.radio.current!.occurrenceId, id);
      expect(f.radio.position.inSeconds, 22);
    },
  );

  test(
    'skipping during retry backoff never reopens the removed playback target',
    () async {
      f.player.onOpen = () async =>
          throw const SocketException('Fixture offline');
      now = const Duration(seconds: 13);
      await f.radio.checkPlaybackConnection();
      f.player.onOpen = null;
      await f.radio.advance();
      expect(f.radio.current!.song.id, 'two');
      now = const Duration(seconds: 15);
      await f.radio.checkPlaybackConnection();
      expect(f.player.opened.length, 3);
      expect(f.radio.current!.song.id, 'two');
    },
  );
}
