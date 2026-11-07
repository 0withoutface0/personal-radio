import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'player_host.dart';
import 'radio_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final name in [
      'LGPL-2.1-or-later',
      'LGPL-3.0-or-later',
      'GPL-3.0-or-later',
    ]) {
      yield LicenseEntryWithLineBreaks([
        'Native libmpv / FFmpeg',
      ], await rootBundle.loadString('native-notices/$name.txt'));
    }
  });
  MediaKit.ensureInitialized();
  final host = PlayerHost();
  await host.initialize();
  final handler = RadioAudioHandler(host.radio);
  host.audio = handler;
  if (Platform.isAndroid) {
    await AudioService.init(
      builder: () => handler,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'dev.personalradio.playback',
        androidNotificationChannelName: 'Radio playback',
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
        androidNotificationIcon: 'drawable/ic_radio_notification',
      ),
    );
  }
  AppLifecycleListener(
    onStateChange: (state) =>
        host.setForeground(state == AppLifecycleState.resumed),
    onExitRequested: () async {
      await host.shutdown();
      return AppExitResponse.exit;
    },
  );
  runApp(
    AnimatedBuilder(
      animation: host,
      builder: (context, _) =>
          RadioApp(key: ObjectKey(host.radio), radio: host.radio, host: host),
    ),
  );
}
