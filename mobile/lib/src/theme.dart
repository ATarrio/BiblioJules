/// Theming, mirroring the web and desktop colour palette.
library;

import 'package:flutter/material.dart';

// Colours with a meaning of their own, so they do not move with the theme.
const Color kEmerald = Color(0xFF34D399);
const Color kAmber = Color(0xFFF59E0B);
const Color kViolet = Color(0xFFA78BFA);
const Color kRed = Color(0xFFF87171);

// Neutral greys for text and icons. Backgrounds, borders and panels come from
// [ColorTheme.surface] instead, so they follow the theme.
const Color kSlate500 = Color(0xFF64748B);
const Color kSlate400 = Color(0xFF94A3B8);
const Color kSlate300 = Color(0xFFCBD5E1);
const Color kSlate100 = Color(0xFFF8FAFC);

/// The theme a fresh installation starts on.
const String kDefaultThemeSlug = 'blue';

/// One selectable theme: the accent, the ink drawn on top of it, and the
/// surface ramp the app paints its backgrounds with.
///
/// This mirrors ``app/themes.json``, which the web and desktop clients read
/// directly, so all three look the same in every theme. ``theme_sync_test.dart``
/// fails if the two copies drift apart: edit the JSON and this list together.
class ColorTheme {
  const ColorTheme({
    required this.slug,
    required this.label,
    required this.ink,
    required this.card,
    required this.surfaces,
    required this.shades,
  });

  /// The identifier stored in the preferences.
  final String slug;

  /// The English name the picker shows (translated by the screen).
  final String label;

  /// The colour of text and icons drawn *on* the accent. White for every theme
  /// but yellow, where white on gold would be unreadable.
  final Color ink;

  /// The light-mode panel colour (near-white, faintly tinted).
  final Color card;

  /// The surface steps, keyed like Tailwind's slate scale. Lightness is slate's
  /// at every step, so text keeps the contrast it was designed with.
  final Map<int, Color> surfaces;

  /// The ten accent shades, keyed the way Tailwind names them.
  final Map<int, Color> shades;

  /// The main accent — the ``500`` shade every theme defines.
  Color get accent => shades[500]!;

  /// One shade of the accent, falling back to the main one.
  Color shade(int value) => shades[value] ?? accent;

  /// One step of the surface ramp (``900`` when unsure).
  Color surface(int value) => surfaces[value] ?? surfaces[900] ?? accent;
}

/// Every theme, in the order the pickers show them (around the colour wheel).
const List<ColorTheme> kThemes = [
  ColorTheme(
    slug: 'red',
    label: 'Red',
    ink: Color(0xFFFFFFFF),
    card: Color(0xFFFFF9F9),
    surfaces: {
      50: Color(0xFFFEF8F8),
      100: Color(0xFFFDF2F0),
      200: Color(0xFFF5E3E1),
      300: Color(0xFFE6CDCB),
      400: Color(0xFFB69A97),
      500: Color(0xFF886B68),
      600: Color(0xFF684C49),
      700: Color(0xFF513937),
      800: Color(0xFF362321),
      900: Color(0xFF231311),
      950: Color(0xFF120303),
    },
    shades: {
      50: Color(0xFFFEF2F2),
      100: Color(0xFFFEE2E2),
      200: Color(0xFFFECACA),
      300: Color(0xFFFCA5A5),
      400: Color(0xFFF87171),
      500: Color(0xFFEF4444),
      600: Color(0xFFDC2626),
      700: Color(0xFFB91C1C),
      800: Color(0xFF991B1B),
      900: Color(0xFF7F1D1D),
    },
  ),
  ColorTheme(
    slug: 'orange',
    label: 'Orange',
    ink: Color(0xFFFFFFFF),
    card: Color(0xFFFFF9F6),
    surfaces: {
      50: Color(0xFFFDF9F6),
      100: Color(0xFFFCF2EE),
      200: Color(0xFFF3E4DC),
      300: Color(0xFFE4CFC4),
      400: Color(0xFFB49C90),
      500: Color(0xFF866D60),
      600: Color(0xFF664E42),
      700: Color(0xFF503B31),
      800: Color(0xFF35241C),
      900: Color(0xFF22140C),
      950: Color(0xFF110400),
    },
    shades: {
      50: Color(0xFFFFF7ED),
      100: Color(0xFFFFEDD5),
      200: Color(0xFFFED7AA),
      300: Color(0xFFFDBA74),
      400: Color(0xFFFB923C),
      500: Color(0xFFF97316),
      600: Color(0xFFEA580C),
      700: Color(0xFFC2410C),
      800: Color(0xFF9A3412),
      900: Color(0xFF7C2D12),
    },
  ),
  ColorTheme(
    slug: 'yellow',
    label: 'Yellow',
    ink: Color(0xFF422006),
    card: Color(0xFFFDFAF5),
    surfaces: {
      50: Color(0xFFFCFAF5),
      100: Color(0xFFF8F4EC),
      200: Color(0xFFEDE7D9),
      300: Color(0xFFDCD3C0),
      400: Color(0xFFABA18A),
      500: Color(0xFF7D725A),
      600: Color(0xFF5D533C),
      700: Color(0xFF483F2B),
      800: Color(0xFF2F2817),
      900: Color(0xFF1D1708),
      950: Color(0xFF0C0600),
    },
    shades: {
      50: Color(0xFFFEFCE8),
      100: Color(0xFFFEF9C3),
      200: Color(0xFFFEF08A),
      300: Color(0xFFFDE047),
      400: Color(0xFFFACC15),
      500: Color(0xFFEAB308),
      600: Color(0xFFCA8A04),
      700: Color(0xFFA16207),
      800: Color(0xFF854D0E),
      900: Color(0xFF713F12),
    },
  ),
  ColorTheme(
    slug: 'green',
    label: 'Green',
    ink: Color(0xFFFFFFFF),
    card: Color(0xFFF7FCF8),
    surfaces: {
      50: Color(0xFFF7FBF8),
      100: Color(0xFFEFF7F0),
      200: Color(0xFFDFEBE0),
      300: Color(0xFFC8D9CA),
      400: Color(0xFF93A897),
      500: Color(0xFF647967),
      600: Color(0xFF455A49),
      700: Color(0xFF344537),
      800: Color(0xFF1E2D21),
      900: Color(0xFF0E1B11),
      950: Color(0xFF010A02),
    },
    shades: {
      50: Color(0xFFF0FDF4),
      100: Color(0xFFDCFCE7),
      200: Color(0xFFBBF7D0),
      300: Color(0xFF86EFAC),
      400: Color(0xFF4ADE80),
      500: Color(0xFF22C55E),
      600: Color(0xFF16A34A),
      700: Color(0xFF15803D),
      800: Color(0xFF166534),
      900: Color(0xFF14532D),
    },
  ),
  ColorTheme(
    slug: 'blue',
    label: 'Blue',
    ink: Color(0xFFFFFFFF),
    card: Color(0xFFF9FBFF),
    surfaces: {
      50: Color(0xFFF8FAFE),
      100: Color(0xFFF1F5FD),
      200: Color(0xFFE1E8F5),
      300: Color(0xFFCBD4E7),
      400: Color(0xFF97A2B8),
      500: Color(0xFF68738A),
      600: Color(0xFF4A546A),
      700: Color(0xFF374053),
      800: Color(0xFF212938),
      900: Color(0xFF111825),
      950: Color(0xFF030614),
    },
    shades: {
      50: Color(0xFFEEF4FF),
      100: Color(0xFFD9E6FF),
      200: Color(0xFFBCD3FF),
      300: Color(0xFF8EB6FF),
      400: Color(0xFF598FFF),
      500: Color(0xFF3366F2),
      600: Color(0xFF2049DB),
      700: Color(0xFF1B3BB0),
      800: Color(0xFF1C368B),
      900: Color(0xFF1C316E),
    },
  ),
  ColorTheme(
    slug: 'purple',
    label: 'Purple',
    ink: Color(0xFFFFFFFF),
    card: Color(0xFFFBFAFD),
    surfaces: {
      50: Color(0xFFFBF9FD),
      100: Color(0xFFF6F3FB),
      200: Color(0xFFEAE4F3),
      300: Color(0xFFD8D0E3),
      400: Color(0xFFA69DB3),
      500: Color(0xFF776E85),
      600: Color(0xFF584F66),
      700: Color(0xFF443C4F),
      800: Color(0xFF2C2535),
      900: Color(0xFF1A1522),
      950: Color(0xFF0A0411),
    },
    shades: {
      50: Color(0xFFFAF5FF),
      100: Color(0xFFF3E8FF),
      200: Color(0xFFE9D5FF),
      300: Color(0xFFD8B4FE),
      400: Color(0xFFC084FC),
      500: Color(0xFFA855F7),
      600: Color(0xFF9333EA),
      700: Color(0xFF7E22CE),
      800: Color(0xFF6B21A8),
      900: Color(0xFF581C87),
    },
  ),
  ColorTheme(
    slug: 'pink',
    label: 'Pink',
    ink: Color(0xFFFFFFFF),
    card: Color(0xFFFEF9FB),
    surfaces: {
      50: Color(0xFFFDF8FA),
      100: Color(0xFFFCF1F5),
      200: Color(0xFFF3E2E8),
      300: Color(0xFFE4CDD5),
      400: Color(0xFFB499A3),
      500: Color(0xFF866A74),
      600: Color(0xFF654B55),
      700: Color(0xFF4F3941),
      800: Color(0xFF35232A),
      900: Color(0xFF221219),
      950: Color(0xFF100308),
    },
    shades: {
      50: Color(0xFFFDF2F8),
      100: Color(0xFFFCE7F3),
      200: Color(0xFFFBCFE8),
      300: Color(0xFFF9A8D4),
      400: Color(0xFFF472B6),
      500: Color(0xFFEC4899),
      600: Color(0xFFDB2777),
      700: Color(0xFFBE185D),
      800: Color(0xFF9D174D),
      900: Color(0xFF831843),
    },
  ),
  ColorTheme(
    slug: 'gray',
    label: 'Gray',
    ink: Color(0xFFFFFFFF),
    card: Color(0xFFFBFBFB),
    surfaces: {
      50: Color(0xFFFAFAFA),
      100: Color(0xFFF4F4F4),
      200: Color(0xFFE7E7E7),
      300: Color(0xFFD4D4D4),
      400: Color(0xFFA2A2A2),
      500: Color(0xFF737373),
      600: Color(0xFF545454),
      700: Color(0xFF404040),
      800: Color(0xFF292929),
      900: Color(0xFF181818),
      950: Color(0xFF070707),
    },
    shades: {
      50: Color(0xFFF9FAFB),
      100: Color(0xFFF3F4F6),
      200: Color(0xFFE5E7EB),
      300: Color(0xFFD1D5DB),
      400: Color(0xFF9CA3AF),
      500: Color(0xFF6B7280),
      600: Color(0xFF4B5563),
      700: Color(0xFF374151),
      800: Color(0xFF1F2937),
      900: Color(0xFF111827),
    },
  ),
];

/// The theme for ``slug`` — the default when it is missing or unknown.
ColorTheme themeBySlug(String? slug) {
  for (final theme in kThemes) {
    if (theme.slug == slug) return theme;
  }
  return kThemes.firstWhere((theme) => theme.slug == kDefaultThemeSlug);
}

/// The stored form of a theme slug: a known one, or the default.
String normalizeThemeSlug(String? slug) => themeBySlug(slug).slug;

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

/// The Material theme for ``theme``: its surfaces, its accent, and the colours
/// that mean something whatever the theme is.
ThemeData buildTheme(ColorTheme theme) {
  final scheme =
      ColorScheme.fromSeed(seedColor: theme.accent, brightness: Brightness.dark).copyWith(
        primary: theme.accent,
        onPrimary: theme.ink,
        secondary: kViolet,
        surface: theme.surface(900),
        onSurface: theme.surface(100),
        surfaceContainerLowest: theme.surface(950),
        surfaceContainerLow: theme.surface(900),
        surfaceContainer: theme.surface(900),
        surfaceContainerHigh: theme.surface(800),
        surfaceContainerHighest: theme.surface(800),
        onSurfaceVariant: theme.surface(300),
        outline: theme.surface(700),
        outlineVariant: theme.surface(700),
        error: kRed,
      );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: theme.surface(950),
    canvasColor: theme.surface(950),
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: theme.surface(900),
      foregroundColor: theme.surface(100),
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: theme.surface(900),
      indicatorColor: theme.accent.withValues(alpha: 0.25),
      labelTextStyle: WidgetStatePropertyAll(
        base.textTheme.labelSmall?.copyWith(color: theme.surface(300)),
      ),
      height: 64,
    ),
    cardTheme: CardThemeData(
      color: theme.surface(900),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.surface(800)),
      ),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: theme.surface(900),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: theme.surface(700)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: theme.surface(700)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: theme.accent, width: 1.5),
      ),
      labelStyle: TextStyle(color: theme.surface(300)),
      floatingLabelStyle: TextStyle(color: theme.accent),
      isDense: true,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: theme.surface(800),
      selectedColor: theme.accent.withValues(alpha: 0.35),
      side: BorderSide(color: theme.surface(700)),
      labelStyle: TextStyle(color: theme.surface(100)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: theme.surface(900),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: theme.surface(900),
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: theme.surface(800),
      contentTextStyle: TextStyle(color: theme.surface(100)),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    dividerTheme: DividerThemeData(color: theme.surface(800), space: 1, thickness: 1),
    listTileTheme: ListTileThemeData(iconColor: theme.surface(400)),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: theme.accent,
        foregroundColor: theme.ink,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: theme.surface(100),
        side: BorderSide(color: theme.surface(700)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: theme.shade(300)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: theme.accent),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return theme.accent.withValues(alpha: 0.3);
          }
          return theme.surface(900);
        }),
        side: WidgetStatePropertyAll(BorderSide(color: theme.surface(700))),
        foregroundColor: WidgetStatePropertyAll(theme.surface(100)),
      ),
    ),
  );
}
