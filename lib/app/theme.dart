import 'package:flutter/material.dart';

/// Semantic status colours (high contrast: used outdoors by the pool and in
/// dim club areas). Never rely on colour alone: every status also has text.
abstract final class R007Colors {
  static const green = Color(0xFF1B7F3B);
  static const greenDark = Color(0xFF0E5A26);
  static const red = Color(0xFFC62828);
  static const amber = Color(0xFFF2A100);
  static const orange = Color(0xFFE65100);
  static const blue = Color(0xFF1565C0);
  static const grey = Color(0xFF546E7A);
  static const purple = Color(0xFF6A1B9A);
}

/// Base theme: large touch targets (min 56dp), roomy lists, readable text.
ThemeData buildR007Theme({Brightness brightness = Brightness.light}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: R007Colors.green,
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    appBarTheme: const AppBarTheme(centerTitle: false, toolbarHeight: 64),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 56),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 24),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 56),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 24),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(64, 52),
        textStyle: const TextStyle(fontSize: 16),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 18),
    ),
    listTileTheme: const ListTileThemeData(
      minVerticalPadding: 10,
      minTileHeight: 64,
    ),
    cardTheme: const CardThemeData(margin: EdgeInsets.zero),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontSize: 18),
      bodyMedium: TextStyle(fontSize: 16),
      titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
    ),
  );
}
