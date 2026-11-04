import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'support/player_fixture.dart';

void main() {
  late PlayerFixture f;
  setUp(() {
    f = PlayerFixture();
  });
  tearDown(() {
    f.dispose();
  });

  test('intentional replay after queue completion starts at zero with a fresh occurrence', () async {
    final r = f.radio;
    await r.playSongs([song('one')]);
    final original = r.current!.occurrenceId;
    // Simulate saved completion state without creating listening events.
    r.current!.status = 'completed';
    r.position = const Duration(seconds: 180);
    f.player.state = f.player.state.copyWith(completed: true);
    await r.play();
    expect(r.current!.occurrenceId, isNot(original));
    expect(r.position, Duration.zero);
    expect(r.entries.length, 1);
    expect(f.player.opened.length, 2);
    expect(r.outbox, isEmpty);
  });

  test('adding after completion continues to the added song rather than reopening the end', () async {
    final r = f.radio;
    await r.playSongs([song('one')]);
    final original = r.current!.occurrenceId;
    r.current!.status = 'completed';
    f.player.state = f.player.state.copyWith(completed: true);
    await r.enqueue([song('two')]);
    final added = r.entries.last.occurrenceId;
    await r.play();
    expect(r.current!.song.id, 'two');
    expect(r.current!.occurrenceId, added);
    expect(r.entries.first.occurrenceId, original);
    expect(r.outbox, isEmpty);
  });

  test('replaying a previous entry gets a new ID, selecting the current entry resumes it', () async {
    final r = f.radio;
    await r.playSongs([song('one'), song('two')], startIndex: 1);
    final old = r.entries.first.occurrenceId;
    await r.selectEntry(0);
    expect(r.current!.song.id, 'one');
    expect(r.current!.occurrenceId, isNot(old));
    final replay = r.current!.occurrenceId;
    await r.selectEntry(0);
    expect(r.current!.occurrenceId, replay);
    expect(f.player.opened.length, 2);
    expect(r.outbox, isEmpty);
  });

  test('a corrected skipped entry opens its own stream instead of the previously loaded song', () async {
    final r = f.radio;
    f.unmatched.add('two');
    await r.playSongs([song('one'), song('two')]);
    await r.prefetch();
    await r.advance();
    expect(r.current!.status, 'skipped');
    r.current!.tidal = {'id': 456, 'duration': 180};
    r.current!.status = 'matched';
    await r.play();
    final streams = f.requests.where((q) => q.url.path == '/api/streams');
    expect(streams.length, 2);
    expect(jsonDecode(streams.last.body)['tidal_id'], 456);
    expect(r.outbox, isEmpty);
  });
}
