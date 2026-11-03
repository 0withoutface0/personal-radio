import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_radio/disk.dart';
import 'package:personal_radio/models.dart';

void main() {
  test(
    'actual time excludes pauses, buffering, seeks and suspended polling',
    () {
      final clock = ListeningClock();
      double sample(double p, int ms, [bool audible = true]) =>
          clock.sample(p, Duration(milliseconds: ms), audible: audible);
      expect(sample(0, 0), 0);
      expect(sample(.5, 500), .5);
      expect(sample(1, 1000), .5);
      expect(sample(1, 2000, false), 0);
      expect(sample(1, 4000), 0);
      expect(sample(1.5, 4500), .5);
      expect(sample(100, 5000), 0);
      expect(sample(100.5, 5500), .5);
      expect(sample(10, 6000), 0);
      expect(sample(11, 16000), 0);
      expect(clock.total, 2);
      clock.reset();
      expect(sample(20, 17000), 0);
    },
  );

  test('wall time cannot overcount a stalled media position', () {
    final clock = ListeningClock();
    clock.sample(0, Duration.zero, audible: true);
    expect(
      clock.sample(.01, const Duration(seconds: 1), audible: true),
      closeTo(.01, .0001),
    );
    expect(clock.sample(.01, const Duration(seconds: 2), audible: true), 0);
  });

  test('queue occurrence identity and pending events survive restart and torn state', () async {
    final directory = await Directory.systemTemp.createTemp('radio-test-');
    addTearDown(() => directory.delete(recursive: true));
    final entry = QueueEntry(
      Song({
        'video_id': 'seed',
        'title': 'A song',
        'artists': ['An artist'],
      }),
    );
    final disk = RadioDisk(File('${directory.path}/state.json'));
    final state = {
      'entries': [entry.toJson()],
      'outbox': [
        {'id': 'stable-event', 'seconds': 1},
      ],
    };
    final first = disk.save(state);
    // save captures a snapshot before an in-memory mutation can change it.
    (state['outbox'] as List).clear();
    await first;
    final restored = await disk.load();
    expect((restored['outbox'] as List).single['id'], 'stable-event');
    expect(
      QueueEntry.fromJson(restored['entries'][0]).occurrenceId,
      entry.occurrenceId,
    );
    await disk.save(restored);
    await disk.file.writeAsString('{torn write');
    expect((await RadioDisk(disk.file).load())['outbox'], restored['outbox']);
  });
}
