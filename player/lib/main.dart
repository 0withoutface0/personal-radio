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
    if (const bool.fromEnvironment('RADIO_TEST_PAUSED_WAKE_LOCK')) {
      const service = MethodChannel(
        'com.ryanheise.audio_service.handler.methods',
      );
      handler.observePlaybackIdle((idle) async {
        try {
          await service.invokeMethod<void>('setPersonalRadioIdle', {
            'idle': idle,
          });
        } on MissingPluginException {
          // The normal release keeps upstream wake-lock behavior.
        } on PlatformException {
          // A media service may be going away during a mode change.
        }
      });
    }
    const widget = MethodChannel('dev.personalradio/playback_widget');
    handler.observeOccurrence((id) async {
      try {
        await widget.invokeMethod<void>('setOccurrence', id);
      } on MissingPluginException {
        // A headless engine can start without a widget host activity.
      } on PlatformException {
        // The widget is optional and does not control playback initialization.
      }
    });
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
