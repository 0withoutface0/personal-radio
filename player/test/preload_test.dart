import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:personal_radio/api.dart';

import 'support/player_fixture.dart';

void main() {
  late PlayerFixture f;
  setUp(() {
    f = PlayerFixture();
    f.catalog = (_) async => {};
  });
  tearDown(() => f.dispose());

  Future<void> start() async {
    await f.radio.playSongs([song('one'), song('two'), song('three')]);
    await f.radio.prefetch();
    f.radio.position = const Duration(seconds: 100);
  }

  test(
    'only the next stream is buffered near EOF; unheard tracks never register',
    () async {
      final r = f.radio;
      await start();
      r.position = const Duration(seconds: 30);
      await r.preloadNext();
      expect(f.player.state.playlist.medias, hasLength(1));
      r.position = const Duration(seconds: 100);
      final ids = r.entries.map((e) => e.occurrenceId).toList();
      r.mode = 'autoplay';
      r.nextCursor = 'saved-station-context';
      await r.preloadNext();
      await r.preloadNext();
      final medias = f.player.state.playlist.medias;
      expect(medias, hasLength(2));
      expect(medias.last.extras?['occurrence_id'], ids[1]);
      expect(medias.last.httpHeaders?['Authorization'], 'Bearer test');
      expect(
        f.requests.where((q) => q.url.path == '/api/streams'),
        hasLength(2),
      );
      expect(
        f.requests.where((q) => q.url.path == '/api/occurrences'),
        hasLength(1),
      );
      expect(r.outbox, isEmpty);
      expect(r.currentIndex, 0);
      expect(r.nextCursor, 'saved-station-context');
      expect(r.entries.map((e) => e.occurrenceId), ids);
      expect(r.entries[1].status, 'matched');
    },
  );

  test('native EOF adopts buffered audio without reopening and durably orders registration before ratings', () async {
    final r = f.radio;
    await start();
    await r.preloadNext();
    final nextId = r.entries[1].occurrenceId;
    f.beforeRequest = (_) async => throw ApiFailure(0, 'fixture offline');
    r.position = r.duration;
    f.player.state = f.player.state.copyWith(
      playlist: mk.Playlist(f.player.state.playlist.medias, index: 1),
      position: Duration.zero,
    );
    await r.handlePlaylist(f.player.state.playlist);
    await r.sync();
    expect(r.current!.occurrenceId, nextId);
    expect(r.entries.first.status, 'completed');
    expect(r.current!.status, 'playing');
    expect(f.player.opened, hasLength(1));
    expect(f.player.state.playlist.index, 0);
    expect(f.player.state.playlist.medias, hasLength(1));
    expect(r.outbox.map((e) => e['path']), ['/api/events', '/api/occurrences']);
    expect(r.outbox.first['body']['completed'], true);
    expect(r.outbox.last['body']['id'], nextId);
    await r.rate('LIKE');
    final saved = await r.disk.load();
    expect(saved['outbox'].map((e) => e['path']), [
      '/api/events',
      '/api/occurrences',
      '/api/ratings',
    ]);
    expect(saved['entries'][1]['id'], nextId);
    final boundary = f.requests.length;
    f.beforeRequest = null;
    await r.sync();
    final delivered = f.requests.skip(boundary).toList();
    expect(delivered[0].url.path, '/api/events');
    expect(delivered[1].url.path, '/api/occurrences');
    expect(jsonDecode(delivered[1].body)['id'], nextId);
    expect(delivered[2].url.path, '/api/ratings');
    expect(r.outbox, isEmpty);
  });

  test('Play next invalidates a late stream response and preloads the inserted occurrence', () async {
    final r = f.radio;
    await start();
    final waiting = Completer<void>(), entered = Completer<void>();
    f.beforeRequest = (q) async {
      if (q.url.path == '/api/streams') {
        entered.complete();
        await waiting.future;
      }
    };
    final loading = r.preloadNext();
    await entered.future;
    await r.enqueue([song('inserted')], next: true);
    waiting.complete();
    await loading;
    expect(f.player.state.playlist.medias, hasLength(1));
    expect(r.current!.song.id, 'one');
    f.beforeRequest = null;
    await r.preloadNext();
    expect(
      f.player.state.playlist.medias.last.extras?['occurrence_id'],
      r.entries[1].occurrenceId,
    );
    expect(r.entries[1].song.id, 'inserted');
    expect(r.outbox, isEmpty);
  });

  test('remove next and a manual skip preserve order without completing skipped songs', () async {
    final r = f.radio;
    await start();
    await r.preloadNext();
    final second = r.entries[1].occurrenceId;
    await r.removeOccurrence(second);
    expect(f.player.state.playlist.medias, hasLength(1));
    await r.preloadNext();
    expect(
      f.player.state.playlist.medias.last.extras?['occurrence_id'],
      r.entries[1].occurrenceId,
    );
    await r.advance();
    expect(r.current!.song.id, 'three');
    expect(r.entries.first.status, isNot('completed'));
    expect(r.outbox, isEmpty);
    expect(f.player.state.playlist.medias, hasLength(1));
  });

  test('pause cancels a delayed preload, and preparation failure leaves audio alone', () async {
    final r = f.radio;
    await start();
    final waiting = Completer<void>(), entered = Completer<void>();
    f.beforeRequest = (q) async {
      if (q.url.path == '/api/streams') {
        entered.complete();
        await waiting.future;
      }
    };
    final loading = r.preloadNext();
    await entered.future;
    await r.pause();
    waiting.complete();
    await loading;
    expect(f.player.state.playlist.medias, hasLength(1));
    expect(f.player.state.playing, false);
    expect(r.outbox, isEmpty);
    f.beforeRequest = null;
    await r.play();
    f.beforeRequest = (q) async {
      if (q.url.path == '/api/streams') throw ApiFailure(0, 'fixture offline');
    };
    await r.preloadNext();
    expect(f.player.state.playing, true);
    expect(r.error, isNull);
    expect(r.current!.song.id, 'one');
  });

  test('a confirmed takeover during preloading pauses immediately', () async {
    await start();
    f.onLease = () async => throw ApiFailure(409, 'fixture takeover');
    await f.radio.preloadNext();
    expect(f.player.state.playing, false);
    expect(f.radio.hasLease, false);
    expect(f.radio.current!.song.id, 'one');
    expect(f.radio.error, contains('takeover'));
    expect(f.radio.outbox, isEmpty);
  });

  test(
    'native handoff stops when the confirmed playback lease expired',
    () async {
      var now = Duration.zero;
      final isolated = PlayerFixture(leaseNow: () => now);
      addTearDown(isolated.dispose);
      final r = isolated.radio;
      await r.playSongs([song('one'), song('two')]);
      r.position = const Duration(seconds: 170);
      await r.preloadNext();
      now = const Duration(seconds: 21);
      isolated.player.state = isolated.player.state.copyWith(
        playlist: mk.Playlist(isolated.player.state.playlist.medias, index: 1),
      );
      await r.handlePlaylist(isolated.player.state.playlist);
      expect(r.currentIndex, 0);
      expect(isolated.player.state.playing, false);
      expect(r.outbox, isEmpty);
      expect(
        isolated.requests.where((q) => q.url.path == '/api/occurrences'),
        hasLength(1),
      );
    },
  );

  test(
    'native future-entry errors do not reopen healthy current playback',
    () async {
      var now = Duration.zero;
      final isolated = PlayerFixture(leaseNow: () => now);
      addTearDown(isolated.dispose);
      await isolated.radio.playSongs([song('one'), song('two')]);
      now = const Duration(seconds: 1);
      await isolated.radio.handleAudioError();
      expect(isolated.player.opened, hasLength(1));
      expect(isolated.player.state.playing, true);
      expect(isolated.radio.current!.song.id, 'one');
      expect(isolated.radio.outbox, isEmpty);
    },
  );

  test(
    'a failed current stream still reconnects at its saved position',
    () async {
      await start();
      final id = f.radio.current!.occurrenceId;
      f.radio.buffering = true;
      await f.radio.handleAudioError();
      expect(f.player.opened, hasLength(2));
      expect(f.radio.current!.occurrenceId, id);
      expect(f.player.state.position, const Duration(seconds: 100));
      expect(f.radio.outbox, isEmpty);
    },
  );

  test(
    'seeking back discards the prepared stream until near EOF again',
    () async {
      await start();
      await f.radio.preloadNext();
      expect(f.player.state.playlist.medias, hasLength(2));
      await f.radio.seek(const Duration(seconds: 10));
      await f.radio.preloadNext();
      expect(f.player.state.playlist.medias, hasLength(1));
      expect(f.radio.position, const Duration(seconds: 10));
      expect(f.radio.outbox, isEmpty);
    },
  );

  test('uncertain recordings are skipped visibly and the next confident occurrence is buffered', () async {
    f.unmatched.add('two');
    await start();
    await f.radio.preloadNext();
    expect(f.radio.entries[1].status, 'skipped');
    expect(f.radio.entries[1].reason, 'Ambiguous');
    expect(
      f.player.state.playlist.medias.last.extras?['occurrence_id'],
      f.radio.entries[2].occurrenceId,
    );
    expect(
      f.requests.where((q) => q.url.path == '/api/occurrences'),
      hasLength(1),
    );
  });
}
