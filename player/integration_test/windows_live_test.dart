// Opt-in live test. Plays real audio and reports actual listening to the paired account.
// Set RADIO_PAIRING_FILE to a local JSON file containing origin and device token.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:personal_radio/app.dart';
import 'package:personal_radio/disk.dart';
import 'package:personal_radio/radio_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native FLAC, pause, seek, natural advance and restart', (
    tester,
  ) async {
    if (!Platform.environment.containsKey('RADIO_PAIRING_FILE')) {
      fail('Set RADIO_PAIRING_FILE to opt into real account playback.');
    }
    MediaKit.ensureInitialized();
    final directory = await Directory.systemTemp.createTemp(
      'personal-radio-live-',
    );
    final disk = RadioDisk(File('${directory.path}/state.json'));
    var radio = RadioController(disk);
    await radio.initialize();
    final playbackErrors = <String>[];
    radio.player!.stream.error.listen(
      (e) =>
          playbackErrors.add(e.replaceAll(RegExp(r'https?://\S+'), '[stream]')),
    );
    await tester.pumpWidget(RadioApp(radio: radio));
    expect(radio.ready, true);
    await radio.search('yeule Too Dead Inside');
    final song = radio.results.firstWhere((s) => s.id == 'ymqvY-Fvf-E');
    await radio.start(song: song);
    final occurrence = radio.current!.occurrenceId;
    final initialIndex = radio.currentIndex;
    expect(radio.current!.song.id, song.id);
    await Future<void>.delayed(const Duration(seconds: 12));
    expect(
      radio.position.inSeconds,
      greaterThan(5),
      reason:
          'error=${radio.error}; playing=${radio.playing}; buffering=${radio.buffering}; duration=${radio.duration}; native=$playbackErrors',
    );
    expect(radio.quality?['verified'], true);
    await radio.pause();
    await radio.sync();
    final before =
        (await radio.api!.call('/api/occurrences/$occurrence'))['listened']
            as num;
    await Future<void>.delayed(const Duration(seconds: 3));
    await radio.sync();
    final paused =
        (await radio.api!.call('/api/occurrences/$occurrence'))['listened']
            as num;
    expect(paused - before, lessThan(.5));
    // A backward seek must add no played time; listening again counts as actual listening.
    await radio.seek(const Duration(seconds: 2));
    await radio.play();
    const fullTrack = bool.fromEnvironment('RADIO_FULL_TRACK');
    if (fullTrack) {
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      while (radio.currentIndex == initialIndex &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } else {
      await Future<void>.delayed(const Duration(seconds: 10));
      await radio.advance();
    }
    final openDeadline = DateTime.now().add(const Duration(seconds: 45));
    while (radio.current?.status != 'playing' &&
        DateTime.now().isBefore(openDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(radio.currentIndex, greaterThan(initialIndex), reason: radio.error);
    await radio.pause();
    await radio.sync();
    final complete = await radio.api!.call('/api/occurrences/$occurrence');
    if (fullTrack) {
      expect(complete['completed'], 1);
      expect(complete['listened'], greaterThan(195));
    } else {
      expect(complete['listened'], lessThan(28));
      expect(complete['completed'], 0);
    }
    expect(radio.outbox, isEmpty);
    final savedOccurrence = radio.current!.occurrenceId;
    final savedPosition = radio.position;
    await radio.shutdown();
    radio = RadioController(disk);
    await radio.initialize();
    expect(radio.current!.occurrenceId, savedOccurrence);
    expect(
      (radio.position - savedPosition).inMilliseconds.abs(),
      lessThan(1000),
    );
    await radio.play();
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(radio.position, greaterThan(savedPosition));
    await radio.pause();
    await radio.sync();
    await radio.shutdown();
    // Retain the local test snapshot as reviewable evidence; it contains no provider credentials.
    // ignore: avoid_print
    print('Live native playback passed. State: ${disk.file.path}');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
