import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_radio/history_files.dart';

void main() {
  test('history files round trip and authenticate their contents', () async {
    final archive = <String, dynamic>{
      'version': 1,
      'tracks': {
        'fixture': {'title': 'T\u00f6nkretessz\u00fck'},
      },
      'events': [],
    };
    final passphrase = 'a fixture passphrase';
    final file = await encryptHistory(archive, passphrase);
    expect(utf8.decode(file, allowMalformed: true), isNot(contains('fixture')));
    expect(await decryptHistory(file, passphrase), archive);
    await expectLater(decryptHistory(file, 'wrong'), throwsFormatException);
    file[file.length - 1] ^= 1;
    await expectLater(decryptHistory(file, passphrase), throwsFormatException);
  });

  test(
    'page iterator freezes the export snapshot after the first page',
    () async {
      final cursors = <int>[];
      await readHistoryPages(
        localOnly: true,
        read: (query) async {
          final params = Uri.parse(query).queryParameters;
          final first = params['after'] == '0';
          expect(params['through'], first ? null : '80');
          expect(params['local_only'], 'true');
          return {
            'after': first ? 12 : 80,
            'through': 80,
            'archive': <String, dynamic>{},
          };
        },
        consume: (_, cursor) async {
          cursors.add(cursor);
        },
      );
      expect(cursors, [12, 80]);
    },
  );
}
