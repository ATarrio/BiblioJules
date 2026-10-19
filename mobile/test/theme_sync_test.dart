import 'dart:convert';
import 'dart:io';

import 'package:bibliojules_mobile/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The palettes live in ``app/themes.json`` so the web, desktop and Android
/// clients look identical. Android cannot read that file at runtime, so the
/// table is mirrored in ``lib/src/theme.dart`` — and this test fails the moment
/// the two drift apart.
void main() {
  final source = File('../app/themes.json');

  test('the shared palette file is where we expect it', () {
    expect(
      source.existsSync(),
      isTrue,
      reason: 'run this test from the mobile/ directory',
    );
  });

  test('every theme in app/themes.json is mirrored exactly', () {
    final data = jsonDecode(source.readAsStringSync()) as Map<String, dynamic>;
    final raw = (data['themes'] as List).cast<Map<String, dynamic>>();

    expect(
      kThemes.map((theme) => theme.slug).toList(),
      raw.map((theme) => theme['slug']).toList(),
      reason: 'the slugs and their order must match app/themes.json',
    );

    for (var index = 0; index < raw.length; index++) {
      final expected = raw[index];
      final actual = kThemes[index];
      final slug = expected['slug'] as String;

      expect(actual.label, expected['label'], reason: '$slug: label');
      expect(
        actual.ink,
        _parse(expected['ink'] as String),
        reason: '$slug: ink',
      );

      final shades = expected['scale'] as Map<String, dynamic>;
      expect(
        actual.shades.keys.toSet(),
        shades.keys.map(int.parse).toSet(),
        reason: '$slug: shade numbers',
      );
      for (final entry in shades.entries) {
        expect(
          actual.shade(int.parse(entry.key)),
          _parse(entry.value as String),
          reason: '$slug: shade ${entry.key}',
        );
      }

      final surfaces = expected['surface'] as Map<String, dynamic>;
      expect(
        actual.surfaces.keys.toSet(),
        surfaces.keys.where((key) => key != 'card').map(int.parse).toSet(),
        reason: '$slug: surface numbers',
      );
      for (final entry in surfaces.entries) {
        if (entry.key == 'card') continue;
        expect(
          actual.surface(int.parse(entry.key)),
          _parse(entry.value as String),
          reason: '$slug: surface ${entry.key}',
        );
      }
      expect(
        actual.card,
        _parse(surfaces['card'] as String),
        reason: '$slug: the light-mode card',
      );
    }
  });

  test('the default theme exists', () {
    expect(kThemes.map((theme) => theme.slug), contains(kDefaultThemeSlug));
  });

  test('unknown slugs fall back to the default', () {
    expect(normalizeThemeSlug('chartreuse'), kDefaultThemeSlug);
    expect(normalizeThemeSlug(null), kDefaultThemeSlug);
    expect(normalizeThemeSlug('pink'), 'pink');
  });
}

/// ``#rrggbb`` (the format the JSON uses) as an opaque colour.
Color _parse(String hex) {
  return Color(0xFF000000 | int.parse(hex.replaceFirst('#', ''), radix: 16));
}
