import 'package:flutter/material.dart';

/// Base theme. Tablets are used in bright outdoor/pool areas and dim club
/// areas, so favour large touch targets and high contrast. Final brand
/// palette is pending design.
ThemeData buildR007Theme() {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B5E20)),
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
  );
}
