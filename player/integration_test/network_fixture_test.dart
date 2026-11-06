// Offline native check: generated silence and a loopback server only.
// No account credentials, radio controller, provider events or ratings.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:personal_radio/playback_network.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native memory cache plays through a stalled HTTP socket', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    mk.MediaKit.ensureInitialized();
    const rate = 8000, seconds = 120;
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
    final release = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        final range = request.headers.value('range');
        final start = range == null
            ? 0
            : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        request.response.headers.set('Accept-Ranges', 'bytes');
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.contentLength = bytes.length - start;
        if (range != null) {
          request.response.statusCode = 206;
          request.response.headers.set(
            'Content-Range',
            'bytes $start-${bytes.length - 1}/${bytes.length}',
          );
        }
        if (start == 0) {
          const split = 44 + rate * 2 * 80;
          request.response.add(bytes.sublist(0, split));
          await request.response.flush();
          await release.future;
          request.response.add(bytes.sublist(split));
        } else {
          request.response.add(bytes.sublist(start));
        }
        await request.response.close();
      } catch (_) {
        /* The player can cancel outstanding range reads on disposal. */
      }
    });
    final player = mk.Player(configuration: networkPlayerConfiguration);
    try {
      await configureNetworkPlayback(player);
      final native = player.platform as mk.NativePlayer;
      expect(double.parse(await native.getProperty('cache-secs')), 90);
      expect(
        int.parse(await native.getProperty('demuxer-max-bytes')),
        96 * 1024 * 1024,
      );
      expect(await native.getProperty('cache-on-disk'), 'no');
      await player.open(
        mk.Media('http://127.0.0.1:${server.port}/silence.wav'),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (player.state.buffer.inSeconds < 30 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(player.state.buffer.inSeconds, greaterThan(30));
      final before = player.state.position;
      await Future<void>.delayed(const Duration(seconds: 5));
      expect(
        player.state.position - before,
        greaterThan(const Duration(seconds: 3)),
      );
      expect(player.state.buffering, false);
    } finally {
      release.complete();
      await player.dispose();
      await server.close(force: true);
    }
  });
}
