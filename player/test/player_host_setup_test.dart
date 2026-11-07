import 'package:flutter_test/flutter_test.dart';
import 'package:personal_radio/player_host.dart';
import 'package:personal_radio/radio_controller.dart';

import 'support/player_fixture.dart';

void main() {
  test(
    'desktop setup keeps an offline server outbox bound to its connection',
    () async {
      final radio = RadioController(MemoryDisk())
        ..origin = 'https://previous.example.invalid'
        ..token = 'previous'
        ..outbox = [
          {'fixture': 'pending'},
        ];
      final host = PlayerHost()..radio = radio;
      addTearDown(host.dispose);
      addTearDown(radio.dispose);

      await expectLater(
        host.installDesktopSetup({
          'mode': 'server',
          'origin': 'https://new.example.invalid',
          'token': 'new',
        }),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('previous server'),
          ),
        ),
      );
      expect(radio.origin, 'https://previous.example.invalid');
      expect(radio.outbox, [
        {'fixture': 'pending'},
      ]);
    },
  );
}
