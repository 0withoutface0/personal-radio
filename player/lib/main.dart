import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'disk.dart';
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
  final support = await getApplicationSupportDirectory();
  final radio = RadioController(
    RadioDisk(File('${support.path}/radio-state.json')),
  );
  await radio.initialize();
  if (Platform.isAndroid) {
    await AudioService.init(
      builder: () => RadioAudioHandler(radio),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'dev.personalradio.playback',
        androidNotificationChannelName: 'Radio playback',
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
        androidNotificationIcon: 'drawable/ic_radio_notification',
      ),
    );
  } else {
    RadioAudioHandler(radio);
  }
  AppLifecycleListener(
    onExitRequested: () async {
      await radio.shutdown();
      return AppExitResponse.exit;
    },
  );
  runApp(RadioApp(radio: radio));
}
