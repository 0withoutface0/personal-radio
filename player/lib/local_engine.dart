import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef EngineEndpoint = ({String origin, String token});

class LocalEngine {
  static const channel = MethodChannel('dev.personalradio/local_engine');
  Process? _process;
  EngineEndpoint? _endpoint;

  File get _executable => File(
    '${File(Platform.resolvedExecutable).parent.path}/engine/personal_radio_engine.exe',
  );

  Future<bool> available() async {
    if (Platform.isWindows) return _executable.exists();
    if (Platform.isAndroid) {
      return await channel.invokeMethod<bool>('available') ?? false;
    }
    return false;
  }

  Future<EngineEndpoint> start() async {
    if (Platform.isAndroid) {
      return _parse(await channel.invokeMethod<String>('start'));
    }
    if (_endpoint != null) return _endpoint!;
    final data = await getApplicationSupportDirectory();
    final child = await Process.start(
      _executable.path,
      const [],
      workingDirectory: _executable.parent.path,
    );
    _process = child;
    unawaited(child.stderr.drain<void>());
    unawaited(
      child.exitCode.then((_) {
        if (identical(_process, child)) {
          _process = null;
          _endpoint = null;
        }
      }),
    );
    try {
      await channel.invokeMethod<void>('ownProcess', child.pid);
      child.stdin.writeln(
        jsonEncode({'data': '${data.path}/standalone/engine'}),
      );
      final ready = await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15));
      if (!identical(_process, child)) {
        throw const FormatException('Local engine stopped.');
      }
      return _endpoint = _parse(ready);
    } catch (_) {
      await stop();
      throw const FormatException('The local engine could not start.');
    }
  }

  static EngineEndpoint _parse(String? input) {
    final data = input == null ? null : jsonDecode(input);
    final origin = data is Map
        ? Uri.tryParse(data['origin'] as String? ?? '')
        : null;
    final token = data is Map ? data['token'] : null;
    if (origin == null ||
        origin.scheme != 'http' ||
        origin.host != '127.0.0.1' ||
        !origin.hasPort ||
        origin.userInfo.isNotEmpty ||
        origin.path.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        token is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw const FormatException('Invalid local engine response.');
    }
    return (origin: origin.toString(), token: token);
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('stop');
    } else {
      final child = _process;
      _endpoint = null;
      _process = null;
      if (child == null) return;
      try {
        await child.stdin.close();
        await child.exitCode.timeout(const Duration(seconds: 6));
      } catch (_) {
        child.kill();
        await child.exitCode;
      }
    }
  }
}
