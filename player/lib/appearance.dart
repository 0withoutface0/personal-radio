import 'package:flutter/material.dart';

enum RadioPalette {
  system('System / Material You', Color(0xFFD5F887)),
  green('Original green', Color(0xFFD5F887)),
  blue('Ocean', Color(0xFF70B7FF)),
  violet('Violet', Color(0xFFBA9CFF)),
  rose('Rose', Color(0xFFFFA4BC)),
  amber('Amber', Color(0xFFFFCA70));

  final String label;
  final Color seed;
  const RadioPalette(this.label, this.seed);
}

class RadioAppearance {
  final RadioPalette palette;
  final ThemeMode mode;
  const RadioAppearance({
    this.palette = RadioPalette.system,
    this.mode = ThemeMode.system,
  });

  factory RadioAppearance.fromJson(dynamic value) {
    if (value is! Map) return const RadioAppearance();
    return RadioAppearance(
      palette: RadioPalette.values.firstWhere(
        (p) => p.name == value['palette'],
        orElse: () => RadioPalette.system,
      ),
      mode: ThemeMode.values.firstWhere(
        (m) => m.name == value['mode'],
        orElse: () => ThemeMode.system,
      ),
    );
  }
  Map<String, String> toJson() => {'palette': palette.name, 'mode': mode.name};
  @override
  bool operator ==(Object other) =>
      other is RadioAppearance &&
      other.palette == palette &&
      other.mode == mode;
  @override
  int get hashCode => Object.hash(palette, mode);
}

ThemeData radioTheme(
  RadioPalette palette,
  Brightness brightness,
  ColorScheme? dynamicScheme,
) {
  var colors = palette == RadioPalette.system && dynamicScheme != null
      ? dynamicScheme
      : ColorScheme.fromSeed(seedColor: palette.seed, brightness: brightness);
  if ((palette == RadioPalette.green ||
          palette == RadioPalette.system && dynamicScheme == null) &&
      brightness == Brightness.dark) {
    colors = colors.copyWith(
      primary: const Color(0xFFD5F887),
      onPrimary: const Color(0xFF111410),
      surface: const Color(0xFF111410),
      surfaceContainerLow: const Color(0xFF1C211B),
      surfaceContainer: const Color(0xFF1C211B),
    );
  }
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Segoe UI',
    colorScheme: colors,
    scaffoldBackgroundColor: colors.surface,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainer,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    ),
    cardTheme: CardThemeData(
      color: colors.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
  );
}
