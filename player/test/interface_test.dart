import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_radio/app.dart';
import 'package:personal_radio/api.dart';
import 'package:personal_radio/disk.dart';
import 'package:personal_radio/models.dart';
import 'package:personal_radio/radio_controller.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1360, 850)]) {
    testWidgets('connection and search layouts fit $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final radio = RadioController(RadioDisk(File('unused-state.json')));
      await tester.pumpWidget(RadioApp(radio: radio));
      expect(find.text('Connect your server'), findsWidgets);
      expect(tester.takeException(), isNull);
      radio.connected = true;
      radio.api = RadioApi('http://127.0.0.1:8765', 'test', radio.deviceId);
      radio.results = [
        Song({
          'title': 'Too Dead Inside',
          'artists': ['yeule'],
          'video_id': 'seed',
        }),
      ];
      radio.update();
      await tester.pump();
      expect(find.byTooltip('Play song'), findsOneWidget);
      await tester.tap(find.byTooltip('Song actions'));
      await tester.pumpAndSettle();
      expect(find.text('Autoplay'), findsOneWidget);
      expect(find.text('Start radio / mix'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      radio.api!.close();
      radio.dispose();
    });
  }
}
