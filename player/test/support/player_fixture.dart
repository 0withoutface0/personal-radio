import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:personal_radio/api.dart';
import 'package:personal_radio/disk.dart';
import 'package:personal_radio/models.dart';
import 'package:personal_radio/radio_controller.dart';

class MemoryDisk extends RadioDisk {
  Map<String, dynamic> saved = {};
  MemoryDisk() : super(File('unused-catalog-test.json'));
  @override
  Future<void> save(Map<String, dynamic> state) async {
    saved = Map<String, dynamic>.from(jsonDecode(jsonEncode(state)));
  }

  @override
  Future<Map<String, dynamic>> load() async => saved;
  @override
  Future<void> get settled => Future.value();
}

// The transport is fake: these tests never open audio, contact a provider,
// report a real play or change either account's ratings.
class FakePlayer extends Fake implements mk.Player {
  @override
  mk.PlayerState state = const mk.PlayerState();
  final List<mk.Media> opened = [];
  @override
  Future<void> open(mk.Playable playable, {bool play = true}) async {
    final media = playable as mk.Media;
    opened.add(media);
    state = mk.PlayerState(playlist: mk.Playlist([media]), playing: play);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
  }

  @override
  Future<void> seek(Duration value) async {
    state = state.copyWith(position: value);
  }
}

Song song(String id, {bool available = true}) => Song({
  'video_id': id,
  'title': 'Song $id',
  'artists': ['Artist'],
  'artist_refs': [
    {'id': 'UC1', 'name': 'Artist'},
  ],
  'album_id': 'MPRE1',
  'album': 'Album',
  'duration': 180,
  'available': available,
});

class PlayerFixture {
  final RadioController radio = RadioController(MemoryDisk());
  final FakePlayer player = FakePlayer();
  final List<http.Request> requests = [];
  final Set<String> unmatched = {};
  Future<Map<String, dynamic>> Function(http.Request)? catalog;
  PlayerFixture() {
    radio.connected = true;
    radio.player = player;
    radio.api = RadioApi(
      'http://127.0.0.1:8765',
      'test',
      radio.deviceId,
      client: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        Map<String, dynamic> result;
        if (path == '/api/match') {
          final source = jsonDecode(request.body);
          result = unmatched.contains(source['video_id'])
              ? {'status': 'skipped', 'reason': 'Ambiguous'}
              : {
                  'status': 'matched',
                  'track': {
                    'id': 123,
                    'duration': 180,
                    'title': source['title'],
                  },
                };
        } else if (path == '/api/occurrences') {
          final body = jsonDecode(request.body);
          // Occurrences must be saved on disk before the (fake) server sees them.
          expect(
            (await radio.disk.load())['entries'].any(
              (e) => e['id'] == body['id'],
            ),
            true,
          );
          result = {'id': body['id']};
        } else if (path == '/api/streams') {
          result = {'id': 'stream', 'url': '/fake.flac'};
        } else if (path.endsWith('/quality')) {
          result = {
            'verified': true,
            'codec': 'flac',
            'bit_depth': 24,
            'sample_rate': 96000,
          };
        } else if (path == '/api/device/lease') {
          result = {'active': true};
        } else if (catalog != null) {
          result = await catalog!(request);
        } else {
          throw StateError('Unexpected request: $path');
        }
        return http.Response(jsonEncode(result), 200);
      }),
    );
  }
  void dispose() {
    radio.api?.close();
    radio.dispose();
  }
}
