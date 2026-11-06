// Generated silence, loopback HTTP and a fake API only. No account activity.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:personal_radio/playback_network.dart';

import '../test/support/player_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final hls in [false, true]) {
    testWidgets(
      'native ${hls ? 'Hi-Res HLS' : 'PCM'} playlist prefetches authenticated audio and adopts it once',
      (tester) async {
        await tester.pumpWidget(const SizedBox());
        mk.MediaKit.ensureInitialized();
        const rate = 44100, seconds = 6;
        final bytes = Uint8List(44 + rate * 2 * seconds);
        final header = ByteData.sublistView(bytes);
        void text(int offset, String value) =>
            bytes.setRange(offset, offset + value.length, value.codeUnits);
        text(0, 'RIFF');
        header.setUint32(4, bytes.length - 8, Endian.little);
        text(8, 'WAVEfmt ');
        header.setUint32(16, 16, Endian.little);
        header.setUint16(20, 1, Endian.little);
        header.setUint16(22, 1, Endian.little);
        header.setUint32(24, rate, Endian.little);
        header.setUint32(28, rate * 2, Endian.little);
        header.setUint16(32, 2, Endian.little);
        header.setUint16(34, 16, Endian.little);
        text(36, 'data');
        header.setUint32(40, bytes.length - 44, Endian.little);
        final f = PlayerFixture();
        final r = f.radio;
        f.catalog = (_) async => {};
        final nextRequested = Completer<void>();
        final requestedBeforeHandoff = <bool>[];
        final auth = <String?>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          auth.add(request.headers.value('authorization'));
          if (request.uri.path == '/fake2.flac' && !nextRequested.isCompleted) {
            requestedBeforeHandoff.add(
              r.currentIndex == 0 && r.position.inSeconds < seconds,
            );
            nextRequested.complete();
          }
          try {
            final payload = hls
                ? (request.uri.path.startsWith('/fake')
                      ? hlsFixture['silence.m3u8']!
                      : hlsFixture[request.uri.path.substring(1)]!)
                : bytes;
            final range = request.headers.value('range');
            final start = range == null
                ? 0
                : int.parse(
                    RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
                  );
            request.response.headers.set('Accept-Ranges', 'bytes');
            request.response.headers.contentType =
                hls && request.uri.path.startsWith('/fake')
                ? ContentType('application', 'vnd.apple.mpegurl')
                : ContentType('audio', hls ? 'mp4' : 'wav');
            request.response.contentLength = payload.length - start;
            if (range != null) {
              request.response.statusCode = 206;
              request.response.headers.set(
                'Content-Range',
                'bytes $start-${payload.length - 1}/${payload.length}',
              );
            }
            request.response.add(payload.sublist(start));
            await request.response.close();
          } catch (_) {
            /* Native range cancellation on shutdown. */
          }
        });
        final native = mk.Player(configuration: networkPlayerConfiguration);
        final time = Stopwatch()..start();
        Duration? lastOld, firstNew;
        r.addListener(() {
          if (r.currentIndex == 0 && r.position.inMilliseconds >= 5000) {
            lastOld = time.elapsed;
          }
          if (r.currentIndex == 1 && r.position > Duration.zero) {
            firstNew ??= time.elapsed;
          }
        });
        Future<void> until(bool Function() condition) async {
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          while (!condition() && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          expect(
            condition(),
            true,
            reason:
                'Native fixture deadline; current=${r.currentIndex} position=${r.position} error=${r.error}',
          );
        }

        try {
          r.origin = 'http://127.0.0.1:${server.port}';
          await r.attachPlayer(native);
          final platform = native.platform as mk.NativePlayer;
          expect(await platform.getProperty('prefetch-playlist'), 'yes');
          expect(await platform.getProperty('gapless-audio'), 'weak');
          await r.playSongs([song('one'), song('two')]);
          await until(
            () => r.duration.inSeconds == seconds && r.position > Duration.zero,
          );
          await r.preloadNext();
          await nextRequested.future.timeout(const Duration(seconds: 4));
          expect(requestedBeforeHandoff, [true]);
          expect(
            f.requests.where((q) => q.url.path == '/api/occurrences'),
            hasLength(1),
          );
          await until(() => firstNew != null);
          expect(r.entries.first.status, 'completed');
          expect(r.entries[1].status, 'playing');
          await r.sync();
          expect(
            f.requests.where((q) => q.url.path == '/api/streams'),
            hasLength(2),
          );
          expect(
            f.requests.where((q) => q.url.path == '/api/occurrences'),
            hasLength(2),
          );
          expect(auth, isNotEmpty);
          expect(auth.every((value) => value == 'Bearer test'), true);
          expect(lastOld, isNotNull);
          expect(
            firstNew! - lastOld!,
            lessThan(const Duration(milliseconds: 900)),
          );
          // Observation interval includes the native 200ms position sampling.
          debugPrint(
            'Prepared handoff observation: ${(firstNew! - lastOld!).inMilliseconds}ms; next HTTP opened before EOF.',
          );
        } finally {
          await r.shutdown();
          r.dispose();
          await server.close(force: true);
        }
      },
    );
  }
}

// Generated 24-bit/96kHz silent FLAC in fMP4 HLS, gzip-compressed for source size.
final hlsFixture = <String, List<int>>{
  'init.mp4': gzip.decode(
    base64Decode(
      'H4sIAAAAAAAC/5VRvU7DMBC+pB0ZGJBYMgSUgQGqlp/MSCwM3RBCSCxu7aihdhzZToBOPAgvwDOwoj4FEq/AwANwdhrJbaESp1jffZf7zuc7AIgy81TmWp4BhGARTyrK0wHyDyFlDQBc1BMKvgUPC3SfF4dlW+HnsNFCFHwaRabo35mpu7OzobqLBf+/N2HUaMSIcW3WFE3BG0Fzgk4s6O9vv353cDShXLW/tKwKP/UKOb0kBeXM5gShyIsMnW0tloomtIlHVLHMa2OrUjxe+HNtRhxxpo2mXs59NiQXa48Iwerg7dmxY4pJ1kG634WuC8Yvu2Xn649V7IyMakYTfDfHdm3c2FpDrse+BvlspQ7mjKXHD0TNHu3lRjlsu15dIKmosR3fCubQ2p4/alyPImXJfdFh3uwzeTVSunESJ3bFh6TO0pNe2hv0+z+ceqNx+AIAAA==',
    ),
  ),
  'segment0.m4s': gzip.decode(
    base64Decode(
      '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',
    ),
  ),
  'segment1.m4s': gzip.decode(
    base64Decode('H4sIAAAAAAAC/2NgYJAoLqksyC1OyWAAAhCdW5xZAQBrgT1WGAAAAA=='),
  ),
  'silence.m3u8': gzip.decode(
    base64Decode(
      'H4sIAAAAAAAC/1N2jQjxNQ7lUgbSuhG6Ya5BwZ7+flbmMIEQxyB31xCX0CDHEJC4GUzc19XF01E32DUw1NXP2dXKAC7uGGAVGuRpq5SZl1mil1tgogSW8fRzszLTMwADHa7i1PTc1LwSA71ck2K4tIGegaGBmZk5XNoQLg0019XPxcczOIQLAKagI+mwAAAA',
    ),
  ),
};
