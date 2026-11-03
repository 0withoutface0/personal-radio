import 'dart:convert';
import 'dart:io';

class RadioDisk {
  final File file;
  Future<void> _writes = Future.value();
  RadioDisk(this.file);
  Future<Map<String, dynamic>> load() async {
    final backup = File('${file.path}.bak');
    for (final candidate in [file, backup]) {
      if (await candidate.exists()) {
        try {
          return Map<String, dynamic>.from(
            jsonDecode(await candidate.readAsString()),
          );
        } catch (_) {
          if (candidate == backup || !await backup.exists()) rethrow;
        }
      }
    }
    return {};
  }

  Future<void> save(Map<String, dynamic> state) {
    final json = jsonEncode(state);
    _writes = _writes.catchError((Object _) {}).then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(json, flush: true);
      final backup = File('${file.path}.bak');
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
      }
      await temporary.rename(file.path);
    });
    return _writes;
  }

  Future<void> get settled => _writes;
}
