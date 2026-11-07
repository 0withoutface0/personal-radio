import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'api.dart';

const historyPath = '/api/local/history';
const historyFileLimit = 64 * 1024 * 1024;
const _magic = [80, 82, 72, 1]; // PRH, version 1.
final _cipher = AesGcm.with256bits();

Future<SecretKey> _historyKey(String password, List<int> salt) => Argon2id(
  memory: 19456,
  iterations: 2,
  parallelism: 1,
  hashLength: 32,
).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

Future<Uint8List> encryptHistory(
  Map<String, dynamic> archive,
  String password,
) => Isolate.run(() async {
  final plain = utf8.encode(jsonEncode(archive));
  if (plain.length + 48 > historyFileLimit) {
    throw const FormatException('History is too large for one file.');
  }
  final salt = _cipher.newNonce() + _cipher.newNonce().take(4).toList();
  final box = await _cipher.encrypt(
    plain,
    secretKey: await _historyKey(password, salt),
    aad: _magic,
  );
  return Uint8List.fromList([..._magic, ...salt, ...box.concatenation()]);
});

Future<Map<String, dynamic>> decryptHistory(Uint8List file, String password) =>
    Isolate.run(() async {
      if (file.length <= 48 ||
          file.length > historyFileLimit ||
          !_magic.asMap().entries.every(
            (entry) => file[entry.key] == entry.value,
          )) {
        throw const FormatException('Choose a Personal Radio history file.');
      }
      try {
        final salt = Uint8List.sublistView(file, 4, 20);
        final box = SecretBox.fromConcatenation(
          Uint8List.sublistView(file, 20),
          nonceLength: 12,
          macLength: 16,
        );
        final plain = await _cipher.decrypt(
          box,
          secretKey: await _historyKey(password, salt),
          aad: _magic,
        );
        return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      } on SecretBoxAuthenticationError {
        throw const FormatException(
          'The passphrase is wrong or the file is damaged.',
        );
      }
    });

Future<void> readHistoryPages({
  required Future<dynamic> Function(String query) read,
  required Future<void> Function(Map<String, dynamic> archive, int cursor)
  consume,
  int after = 0,
  bool localOnly = false,
}) async {
  int? through;
  do {
    final page = await read(
      '?after=$after&local_only=$localOnly${through == null ? '' : '&through=$through'}',
    );
    final next = page['after'] as int;
    through ??= page['through'] as int;
    if (next < after || next > through || (next == after && next != through)) {
      throw const FormatException(
        'History cursor has changed. Pair again to resync.',
      );
    }
    await consume(page['archive'] as Map<String, dynamic>, next);
    after = next;
  } while (after < through);
}

Future<Map<String, dynamic>> collectHistory(RadioApi api) async {
  final tracks = <String, dynamic>{};
  final events = <dynamic>[];
  await readHistoryPages(
    read: (query) => api.call('$historyPath$query'),
    consume: (archive, _) async {
      tracks.addAll(archive['tracks'] as Map<String, dynamic>);
      events.addAll(archive['events'] as List);
      if (events.length > 500000 || tracks.length > 200000) {
        throw const FormatException('History is too large for one file.');
      }
    },
  );
  return {'version': 1, 'tracks': tracks, 'events': events};
}
