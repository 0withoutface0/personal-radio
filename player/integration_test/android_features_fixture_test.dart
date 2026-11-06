// Native Android integrations with isolated fake transport/provider activity.
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_radio/app.dart';
import 'package:personal_radio/appearance.dart';
import 'package:personal_radio/models.dart';
import 'package:personal_radio/radio_controller.dart';

import '../test/support/player_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android Monet colors and foreground media Like use native plugins',
    (tester) async {
      if (!Platform.isAndroid) {
        return;
      }
      final f = PlayerFixture();
      final r = f.radio;
      final sent = <Map<String, dynamic>>[];
      f.catalog = (request) async {
        if (request.url.path == '/api/ratings') {
          sent.add(jsonDecode(request.body));
        }
        return request.url.path == '/api/report' ? {'submissions': []} : {};
      };
      r.entries = [
        QueueEntry(song('fixture'), tidal: {'id': 123}),
      ];
      r.currentIndex = 0;
      r.playing = true;
      r.duration = const Duration(seconds: 180);
      r.home = {};
      final handler = await AudioService.init(
        builder: () => RadioAudioHandler(r),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'dev.personalradio.playback',
          androidNotificationChannelName: 'Radio playback',
          androidStopForegroundOnPause: false,
          androidNotificationIcon: 'drawable/ic_radio_notification',
        ),
      );
      try {
        final core = await DynamicColorPlugin.getCorePalette();
        expect(
          core,
          isNotNull,
          reason: 'Android 12+ supplies the native Monet palette',
        );
        await tester.pumpWidget(RadioApp(radio: r));
        final light = core!.toColorScheme();
        await r.setAppearance(const RadioAppearance(mode: ThemeMode.light));
        for (int i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (Theme.of(tester.element(find.byType(Scaffold).first))
                  .colorScheme
                  .primary ==
              light.primary) {
            break;
          }
        }
        expect(
          Theme.of(tester.element(find.byType(Scaffold).first))
              .colorScheme
              .primary,
          light.primary,
        );
        await r.setAppearance(
          const RadioAppearance(
            palette: RadioPalette.green,
            mode: ThemeMode.dark,
          ),
        );
        await tester.pumpAndSettle();
        final green = Theme.of(tester.element(find.byType(Scaffold).first));
        expect(green.brightness, Brightness.dark);
        expect(green.colorScheme.primary, const Color(0xFFD5F887));
        expect(tester.takeException(), isNull);
        MediaControl like() => handler.playbackState.value.controls.singleWhere(
          (c) => c.customAction?.name == RadioAudioHandler.likeAction,
        );
        final original = like().customAction!;
        await handler.customAction(original.name, original.extras);
        expect(sent.single['value'], 'LIKE');
        expect(sent.single['tidal_favorite'], true);
        expect(like().androidIcon, endsWith('filled'));
        await handler.customAction(original.name, original.extras);
        expect(sent, hasLength(1));
        expect(handler.mediaItem.value!.rating!.hasHeart(), true);
        debugPrint(
          'NATIVE_ANDROID_FEATURES_READY: Monet palette and native foreground Like published; provider requests are mocked.',
        );
        if (const bool.fromEnvironment('RADIO_INSPECT_MEDIA')) {
          await Future<void>.delayed(const Duration(seconds: 20));
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await handler.stop();
        f.dispose();
      }
    },
  );
}
