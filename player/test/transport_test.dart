import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_radio/disk.dart';
import 'package:personal_radio/models.dart';
import 'package:personal_radio/radio_controller.dart';

void main() {
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
