import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_radio/api.dart';
import 'package:personal_radio/device_peer.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('pair codes are scoped to their purpose and private IPv4 addresses', () {
    final token = List.filled(43, 'a').join();
    final code = PairCode(
      PairPurpose.youtube,
      '192.168.5.12',
      34567,
      token,
      token,
    );
    expect(PairCode.decode(code.encode(), PairPurpose.youtube).host, code.host);
    expect(
      () => PairCode.decode(code.encode(), PairPurpose.history),
      throwsFormatException,
    );
    for (final address in [
      '127.0.0.1',
      '100.100.100.100',
      '1.1.1.1',
      'localhost',
    ]) {
      expect(privateAddress(address), isFalse);
    }
  });

  test(
    'server setup shares only the saved connection after approval',
    () async {
      final addresses = await lanAddresses();
      if (addresses.isEmpty) {
        markTestSkipped('No private IPv4 interface for the TLS fixture.');
        return;
      }
      expect(
        () => shareableServer('http://127.0.0.1:8765', 'fixture'),
        throwsFormatException,
      );
      final desktop = DevicePeer(() => null);
      final phone = DevicePeer(() => null);
      addTearDown(desktop.close);
      addTearDown(phone.close);
      final connection = shareableServer(
        'https://radio.example.invalid',
        'fixture',
      );
      final offer = await desktop.offer(
        addresses.first,
        PairPurpose.setup,
        serverConnection: connection,
      );
      final qr = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(offer.code.encode()))),
      );
      expect(
        qr.keys,
        unorderedEquals([
          'version',
          'purpose',
          'host',
          'port',
          'pin',
          'secret',
        ]),
      );
      await expectLater(
        offer.code.request('/confirm', body: {'installed': true}),
        throwsFormatException,
      );
      final requested = Completer<void>();
      offer.incoming.addListener(requested.complete);
      final received = Completer<Map<String, dynamic>>();
      final installed = Completer<void>();
      final setup = phone.acceptSetup(offer.code.encode(), (payload) async {
        received.complete(payload);
        await installed.future;
      });
      await requested.future.timeout(const Duration(seconds: 8));
      expect(received.isCompleted, isFalse);
      offer.decide(true);
      expect(await received.future, {
        'mode': 'server',
        'origin': connection.origin,
        'token': connection.token,
      });
      expect(offer.finished.isCompleted, isFalse);
      installed.complete();
      await setup;
      expect(await offer.finished.future, isTrue);
      expect(desktop.paired || phone.paired, isFalse);
    },
  );

  test('one scan transfers both accounts and pairs history only after installation', () async {
    final addresses = await lanAddresses();
    if (addresses.isEmpty) {
      markTestSkipped('No private IPv4 interface for the TLS fixture.');
      return;
    }
    final accounts = {
      'youtube': {'cookie': 'synthetic'},
      'tidal': {'access_token': 'synthetic'},
    };
    final api = RadioApi(
      'http://127.0.0.1:1234',
      'test',
      'windows',
      client: MockClient((request) async {
        expect(request.url.path, '/api/local/accounts/setup/transfer');
        return _reply(accounts);
      }),
    );
    final desktop = DevicePeer(() => api);
    final phone = DevicePeer(() => null);
    addTearDown(api.close);
    addTearDown(desktop.close);
    addTearDown(phone.close);
    final first = await desktop.offer(
      addresses.first,
      PairPurpose.setup,
      shareHistory: true,
    );
    first.incoming.addListener(() => first.decide(true));
    await expectLater(
      phone.acceptSetup(
        first.code.encode(),
        (_) async => throw const FormatException('Bad fixture'),
      ),
      throwsFormatException,
    );
    expect(await first.finished.future, isFalse);
    expect(desktop.paired || phone.paired, isFalse);
    await desktop.closeOffer();

    final offer = await desktop.offer(
      addresses.first,
      PairPurpose.setup,
      shareHistory: true,
    );
    offer.incoming.addListener(() => offer.decide(true));
    await phone.acceptSetup(offer.code.encode(), (payload) async {
      expect(payload['mode'], 'local');
      expect(payload['accounts'], accounts);
      expect(payload['history']['purpose'], 'history');
      expect(desktop.paired || phone.paired, isFalse);
    });
    expect(await offer.finished.future, isTrue);
    expect(desktop.serving && phone.paired, isTrue);
    await expectLater(
      offer.code.request('/confirm', body: {'installed': true}),
      throwsFormatException,
    );
  });

  test('desktop requires approval and its pinned session code can only be used once', () async {
    final addresses = await lanAddresses();
    if (addresses.isEmpty) {
      markTestSkipped('No private IPv4 interface for the TLS fixture.');
      return;
    }
    var sent = 0;
    var received = 0;
    final desktopApi = RadioApi(
      'http://127.0.0.1:1234',
      'test',
      'windows',
      client: MockClient((request) async {
        expect(request.url.path, '/api/local/accounts/youtube/transfer');
        sent++;
        return _reply({
          'auth': {'cookie': 'TEST_SESSION=fixture'},
        });
      }),
    );
    final phoneApi = RadioApi(
      'http://127.0.0.1:1234',
      'test',
      'android',
      client: MockClient((request) async {
        expect(request.url.path, '/api/local/accounts/youtube');
        final body = jsonDecode(request.body);
        expect(jsonDecode(body['text']), {'cookie': 'TEST_SESSION=fixture'});
        received++;
        return _reply({});
      }),
    );
    final desktop = DevicePeer(() => desktopApi);
    final phone = DevicePeer(() => phoneApi);
    addTearDown(desktop.close);
    addTearDown(phone.close);
    final offer = await desktop.offer(addresses.first, PairPurpose.youtube);
    final wrong = PairCode(
      offer.code.purpose,
      offer.code.host,
      offer.code.port,
      List.filled(43, 'b').join(),
      offer.code.secret,
    );
    await expectLater(wrong.request('/pair', body: {}), throwsA(anything));
    expect(offer.incoming.value, isNull);
    final requested = Completer<void>();
    offer.incoming.addListener(() => requested.complete());
    final accepted = phone.accept(offer.code.encode(), PairPurpose.youtube);
    await requested.future.timeout(const Duration(seconds: 8));
    expect(sent, 0);
    offer.decide(true);
    await accepted;
    expect(await offer.finished.future, isTrue);
    expect(sent, 1);
    expect(received, 1);
    await expectLater(
      phone.accept(offer.code.encode(), PairPurpose.youtube),
      throwsFormatException,
    );
  });

  test('Wi-Fi sync exchanges history pages without calling account or activity routes', () async {
    final addresses = await lanAddresses();
    if (addresses.isEmpty) {
      markTestSkipped('No private IPv4 interface for the TLS fixture.');
      return;
    }
    final synced = <String, List<String>>{'windows': [], 'android': []};
    RadioApi fake(String device) => RadioApi(
      'http://127.0.0.1:1234',
      'test',
      device,
      client: MockClient((request) async {
        expect(request.url.path, '/api/local/history');
        if (request.method == 'POST') {
          final body = jsonDecode(request.body);
          synced[device]!.add(body['events'][0]['id'] as String);
          return _reply({'inserted': 1});
        }
        final params = request.url.queryParameters;
        expect(params['local_only'], 'true');
        return _reply({
          'after': 1,
          'through': 1,
          'archive': {
            'version': 1,
            'tracks': {},
            'events': [
              if (params['after'] == '0') {'id': device},
            ],
          },
        });
      }),
    );
    final desktopApi = fake('windows');
    final phoneApi = fake('android');
    final desktop = DevicePeer(() => desktopApi);
    final phone = DevicePeer(() => phoneApi);
    addTearDown(desktop.close);
    addTearDown(phone.close);
    final offer = await desktop.offer(addresses.first, PairPurpose.history);
    offer.incoming.addListener(() => offer.decide(true));
    await phone.accept(offer.code.encode(), PairPurpose.history);
    expect(await offer.finished.future, isTrue);
    await phone.sync();
    await phone.sync();
    expect(synced, {
      'windows': ['android'],
      'android': ['windows'],
    });
  });
}

http.Response _reply(Map<String, dynamic> data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
