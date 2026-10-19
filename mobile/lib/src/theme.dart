/// Theming, mirroring the web and desktop colour palette.
library;

import 'package:flutter/material.dart';

// Palette shared with ``app/desktop/theme.py`` and the web stylesheet.
const Color kBrand = Color(0xFF3366F2);
const Color kBrandDark = Color(0xFF2049DB);
const Color kSlate950 = Color(0xFF020617);
const Color kSlate900 = Color(0xFF0F172A);
const Color kSlate800 = Color(0xFF1E293B);
const Color kSlate700 = Color(0xFF334155);
const Color kSlate500 = Color(0xFF64748B);
const Color kSlate400 = Color(0xFF94A3B8);
const Color kSlate300 = Color(0xFFCBD5E1);
const Color kSlate100 = Color(0xFFF8FAFC);
const Color kEmerald = Color(0xFF34D399);
const Color kAmber = Color(0xFFF59E0B);
const Color kViolet = Color(0xFFA78BFA);
const Color kRed = Color(0xFFF87171);

/// Parse ``#rrggbb`` (the format status colours are stored in).
Color parseHexColor(String? value, {Color fallback = kSlate500}) {
  if (value == null) return fallback;
  var hex = value.trim().replaceFirst('#', '');
  if (hex.length == 3) {
    hex = hex.split('').map((c) => '$c$c').join();
  }
  if (hex.length != 6) return fallback;
  final parsed = int.tryParse(hex, radix: 16);
  return parsed == null ? fallback : Color(0xFF000000 | parsed);
}

ThemeData buildTheme() {
  final scheme =
      ColorScheme.fromSeed(seedColor: kBrand, brightness: Brightness.dark).copyWith(
        primary: kBrand,
        onPrimary: Colors.white,
        secondary: kViolet,
        surface: kSlate900,
        onSurface: kSlate100,
        surfaceContainerLowest: kSlate950,
        surfaceContainerLow: kSlate900,
        surfaceContainer: kSlate900,
        surfaceContainerHigh: kSlate800,
        surfaceContainerHighest: kSlate800,
        onSurfaceVariant: kSlate300,
        outline: kSlate700,
        outlineVariant: kSlate700,
        error: kRed,
      );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kSlate950,
    canvasColor: kSlate950,
  );

  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: kSlate900,
      foregroundColor: kSlate100,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: kSlate900,
      indicatorColor: kBrand.withValues(alpha: 0.25),
      labelTextStyle: WidgetStatePropertyAll(
        base.textTheme.labelSmall?.copyWith(color: kSlate300),
      ),
      height: 64,
    ),
    cardTheme: CardThemeData(
      color: kSlate900,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: kSlate800),
      ),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kSlate900,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kSlate700),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kSlate700),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kBrand, width: 1.5),
      ),
      labelStyle: const TextStyle(color: kSlate300),
      floatingLabelStyle: const TextStyle(color: kBrand),
      isDense: true,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: kSlate800,
      selectedColor: kBrand.withValues(alpha: 0.35),
      side: const BorderSide(color: kSlate700),
      labelStyle: const TextStyle(color: kSlate100),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: kSlate900,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: kSlate900,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: kSlate800,
      contentTextStyle: const TextStyle(color: kSlate100),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    dividerTheme: const DividerThemeData(color: kSlate800, space: 1, thickness: 1),
    listTileTheme: const ListTileThemeData(iconColor: kSlate400),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kBrand,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kSlate100,
        side: const BorderSide(color: kSlate700),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Color(0xFF8EB6FF)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: kBrand),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return kBrand.withValues(alpha: 0.3);
          }
          return kSlate900;
        }),
        side: const WidgetStatePropertyAll(BorderSide(color: kSlate700)),
        foregroundColor: const WidgetStatePropertyAll(kSlate100),
      ),
    ),
  );
}
