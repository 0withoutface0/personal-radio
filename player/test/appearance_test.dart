import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_radio/app.dart';
import 'package:personal_radio/appearance.dart';
import 'package:personal_radio/models.dart';

import 'support/player_fixture.dart';

void main() {
  const channel = MethodChannel('io.material.plugins/dynamic_color');
  late PlayerFixture f;
  var accent = 0xFF0067C0;
  setUp(() {
    accent = 0xFF0067C0;
    f = PlayerFixture();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'getAccentColor' ? accent : null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    f.dispose();
  });

  test('fresh and unknown preferences default to system, with durable local selection', () async {
    expect(RadioAppearance.fromJson(null), const RadioAppearance());
    expect(
      RadioAppearance.fromJson({'palette': 'future', 'mode': 'future'}),
      const RadioAppearance(),
    );
    f.radio.entries = [QueueEntry(song('kept'))];
    f.radio.currentIndex = 0;
    f.radio.position = const Duration(seconds: 22);
    f.radio.nextCursor = 'kept-cursor';
    f.radio.outbox = [
      {'id': 'kept-event'},
    ];
    final before = f.radio.snapshot()..remove('appearance');
    await f.radio.setAppearance(
      const RadioAppearance(palette: RadioPalette.rose, mode: ThemeMode.light),
    );
    final saved = await f.radio.disk.load();
    expect(RadioAppearance.fromJson(saved['appearance']), f.radio.appearance);
    expect(f.radio.snapshot()..remove('appearance'), before);
    expect(f.requests, isEmpty);
  });

  testWidgets('system colors and brightness follow OS and refresh on resume', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(RadioApp(radio: f.radio));
    await tester.pumpAndSettle();
    ThemeData theme() => Theme.of(tester.element(find.byType(RadioHome)));
    expect(theme().brightness, Brightness.dark);
    expect(
      theme().colorScheme.primary,
      ColorScheme.fromSeed(
        seedColor: Color(accent),
        brightness: Brightness.dark,
      ).primary,
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(theme().brightness, Brightness.light);
    accent = 0xFFAC2452;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(
      theme().colorScheme.primary,
      ColorScheme.fromSeed(seedColor: Color(accent)).primary,
    );
    expect(f.requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'original green is preserved and forced dark ignores system brightness',
    (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await f.radio.setAppearance(
        const RadioAppearance(
          palette: RadioPalette.green,
          mode: ThemeMode.dark,
        ),
      );
      await tester.pumpWidget(RadioApp(radio: f.radio));
      await tester.pumpAndSettle();
      final theme = Theme.of(tester.element(find.byType(RadioHome)));
      expect(theme.brightness, Brightness.dark);
      expect(theme.colorScheme.primary, const Color(0xFFD5F887));
      expect(theme.scaffoldBackgroundColor, const Color(0xFF111410));
      expect(theme.cardTheme.color, const Color(0xFF1C211B));
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [const Size(390, 844), const Size(1360, 850)]) {
    testWidgets(
      'appearance picker changes color and light mode without playback at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(RadioApp(radio: f.radio));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Connection settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Appearance'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ocean'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Light'));
        await tester.pumpAndSettle();
        expect(
          f.radio.appearance,
          const RadioAppearance(
            palette: RadioPalette.blue,
            mode: ThemeMode.light,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(f.requests, isEmpty);
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.text('Ocean'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(
          Theme.of(tester.element(find.byType(RadioHome))).brightness,
          Brightness.light,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
