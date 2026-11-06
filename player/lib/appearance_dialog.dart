import 'package:flutter/material.dart';

import 'appearance.dart';
import 'radio_controller.dart';

Future<void> showAppearanceDialog(
  BuildContext context,
  RadioController radio,
) => showDialog<void>(
  context: context,
  builder: (context) => AnimatedBuilder(
    animation: radio,
    builder: (context, _) {
      Future<void> select({RadioPalette? palette, ThemeMode? mode}) async {
        try {
          await radio.setAppearance(
            RadioAppearance(
              palette: palette ?? radio.appearance.palette,
              mode: mode ?? radio.appearance.mode,
            ),
          );
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Could not save the appearance. Try again.'),
              ),
            );
          }
        }
      }

      return AlertDialog(
        title: const Text('Appearance'),
        scrollable: true,
        content: SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Color theme'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final palette in RadioPalette.values)
                    ChoiceChip(
                      label: Text(palette.label),
                      selected: radio.appearance.palette == palette,
                      avatar: Icon(
                        palette == RadioPalette.system
                            ? Icons.wallpaper
                            : Icons.circle,
                        color: palette == RadioPalette.system
                            ? Theme.of(context).colorScheme.primary
                            : palette.seed,
                        size: 18,
                      ),
                      onSelected: (selected) {
                        if (selected) select(palette: palette);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'System uses Android wallpaper colors or the Windows accent, with green as the fallback.',
              ),
              const SizedBox(height: 24),
              const Text('Brightness'),
              const SizedBox(height: 12),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ],
                selected: {radio.appearance.mode},
                onSelectionChanged: (value) => select(mode: value.single),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      );
    },
  ),
);
