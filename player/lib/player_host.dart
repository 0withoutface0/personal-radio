import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'device_peer.dart';
import 'disk.dart';
import 'local_engine.dart';
import 'radio_controller.dart';

bool preferLocal({
  required bool supported,
  required String? savedMode,
  required bool existingServer,
}) =>
    supported &&
    (savedMode == 'local' || (savedMode == null && !existingServer));

class PlayerHost extends ChangeNotifier {
  final engine = LocalEngine();
  late final peer = DevicePeer(
    () => radio.localMode && !changing && radio.ready ? radio.api : null,
  );
  bool _foreground = true;
  int _syncTicks = 0;
  void setForeground(bool foreground) {
    _foreground = foreground;
    if (foreground) _syncTicks = 0;
  }

  late final Directory support;
  late final RadioDisk preferences;
  late RadioController radio;
  RadioAudioHandler? audio;
  bool supportsLocal = false;
  bool changing = false;
  Timer? _monitor;
  Future<void>? _recovery;

  Future<void> initialize() async {
    support = await getApplicationSupportDirectory();
    preferences = RadioDisk(File('${support.path}/engine-mode.json'));
    supportsLocal = await engine.available();
    final saved = await preferences.load();
    final legacy = await const FlutterSecureStorage().read(key: 'device_token');
    final oldProfile = await File('${support.path}/radio-state.json').exists();
    final local = preferLocal(
      supported: supportsLocal,
      savedMode: saved['mode'] as String?,
      existingServer:
          oldProfile ||
          (legacy?.isNotEmpty ?? false) ||
          Platform.environment.containsKey('RADIO_PAIRING_FILE'),
    );
    radio = await _open(local);
    if (local) unawaited(peer.restore());
    await preferences.save({'mode': local ? 'local' : 'server'});
    _monitor = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!radio.localMode || !radio.ready || changing) return;
      unawaited(recover());
      if (Platform.isAndroid &&
          _foreground &&
          peer.paired &&
          _syncTicks++ % 8 == 0) {
        unawaited(
          peer.sync().catchError((Object _) {
            // Manual sync shows connection errors when the desktop is available.
          }),
        );
      }
    });
  }

  Future<RadioController> _open(bool local) async {
    final path = local ? 'standalone/player.json' : 'radio-state.json';
    final controller = RadioController(
      RadioDisk(File('${support.path}/$path')),
      localMode: local,
    );
    EngineEndpoint? endpoint;
    try {
      if (local) endpoint = await engine.start();
    } catch (_) {
      // Keep mode controls available so the engine can be retried.
    }
    await controller.initialize(endpoint: endpoint);
    if (local && endpoint == null) {
      controller.error =
          'The local engine could not start. Open Settings to retry.';
    }
    return controller;
  }

  Future<void> installDesktopSetup(Map<String, dynamic> setup) async {
    if (changing) {
      throw const FormatException('Wait for the current mode change.');
    }
    final bool local;
    final Future<void> Function(RadioController) install;
    switch (setup['mode']) {
      case 'local':
        if (!supportsLocal) {
          throw const FormatException(
            'Install the standalone Android build to use this setup code.',
          );
        }
        final accounts = setup['accounts'];
        if (accounts is! Map<String, dynamic>) {
          throw const FormatException('Make a new setup code on Windows.');
        }
        local = true;
        install = (controller) async {
          final api = controller.api;
          if (api == null || !controller.ready) {
            throw const FormatException(
              'Retry the local engine in Settings and scan a new code.',
            );
          }
          await controller.pause();
          await api.call(
            '/api/local/accounts/setup',
            body: accounts,
            timeout: const Duration(seconds: 110),
          );
          await controller.refreshLocalAccounts();
        };
      case 'server':
        final address = setup['origin'];
        final token = setup['token'];
        if (address is! String || token is! String) {
          throw const FormatException('Make a new setup code on Windows.');
        }
        final server = shareableServer(address, token);
        local = false;
        install = (controller) async {
          if (controller.outbox.isNotEmpty &&
              (controller.origin != server.origin ||
                  controller.token != server.token)) {
            throw const FormatException(
              'Sync pending listening events with your previous server before changing servers.',
            );
          }
          await controller.connect(server.origin, server.token);
        };
      default:
        throw const FormatException('Make a new setup code on Windows.');
    }

    if (local == radio.localMode) {
      if (local && !radio.ready) await recover();
      await install(radio);
    } else {
      await _switchMode(local, configure: install);
    }
  }

  Future<void> switchMode(bool local) => _switchMode(local);

  Future<void> _switchMode(
    bool local, {
    Future<void> Function(RadioController)? configure,
  }) async {
    if (changing || local == radio.localMode || (local && !supportsLocal)) {
      return;
    }
    changing = true;
    notifyListeners();
    final old = radio;
    RadioController? candidate;
    try {
      await _recovery;
      if (old.localMode) await peer.close();
      await old.shutdown();
      if (old.localMode) await engine.stop();
      candidate = await _open(local);
      await configure?.call(candidate);
      await preferences.save({'mode': local ? 'local' : 'server'});
      radio = candidate;
      audio?.bind(radio);
      old.dispose();
    } catch (failure) {
      if (candidate != null && identical(old, radio)) {
        try {
          await candidate.shutdown();
        } catch (_) {
          // Restore the current profile even if the discarded player cannot shut down cleanly.
        }
        candidate.dispose();
        if (local) await engine.stop();
      }
      if (identical(old, radio)) {
        radio = await _open(old.localMode);
        audio?.bind(radio);
        old.dispose();
      }
      if (configure != null) rethrow;
      radio.fail(failure);
    } finally {
      changing = false;
      if (radio.localMode) unawaited(peer.restore());
      notifyListeners();
    }
  }

  Future<void> recover() {
    if (!radio.localMode || changing) return Future.value();
    return _recovery ??= _recover().whenComplete(() => _recovery = null);
  }

  Future<void> _recover() async {
    final current = radio;
    try {
      final endpoint = await engine.start();
      if (identical(radio, current) &&
          !changing &&
          (!current.ready ||
              endpoint.origin != current.origin ||
              endpoint.token != current.token)) {
        await current.connect(endpoint.origin, endpoint.token);
      }
    } catch (_) {
      if (identical(radio, current)) {
        current.fail(
          const FormatException(
            'Local engine unavailable. Try again in Settings.',
          ),
        );
      }
    }
  }

  Future<void> shutdown() async {
    _monitor?.cancel();
    await _recovery;
    await peer.close();
    await radio.shutdown();
    if (radio.localMode) await engine.stop();
  }
}
