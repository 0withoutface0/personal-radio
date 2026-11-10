import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_radio/disk.dart';
import 'package:personal_radio/models.dart';
import 'package:personal_radio/radio_controller.dart';

import 'support/player_fixture.dart';

void main() {
  test(
    'wake-lock idle signal follows a settled pause, not internal buffering',
    () async {
      final fixture = PlayerFixture();
      addTearDown(fixture.dispose);
      fixture.catalog = (_) async => {};
      final radio = fixture.radio;
      final handler = RadioAudioHandler(radio);
      final idle = <bool>[];
      handler.observePlaybackIdle(idle.add);
      await radio.playSongs([song('one')]);
      radio.playing = true;
      radio.update();
      radio.playing = false;
      radio.buffering = true;
      radio.update();
      expect(idle, [true, false]);
      await radio.pause();
      radio.update();
      expect(idle, [true, false, true]);
    },
  );

  test('notification stop remains idle after late player updates', () async {
    final directory = await Directory.systemTemp.createTemp('radio-transport-');
    addTearDown(() => directory.delete(recursive: true));
    final radio = RadioController(
      RadioDisk(File('${directory.path}/state.json')),
    );
    radio.entries = [
      QueueEntry(Song({'title': 'Song', 'duration': 180})),
    ];
    radio.currentIndex = 0;
    final handler = RadioAudioHandler(radio);
    radio.playing = true;
    radio.update();
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
    await handler.stop();
    radio.buffering = false;
    radio.duration = Duration.zero;
    radio.update();
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
    expect(handler.playbackState.value.playing, false);
    radio.playing = true;
    radio.update();
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
    radio.dispose();
  });
}
