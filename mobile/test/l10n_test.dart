import 'dart:convert';
import 'dart:io';

import 'package:bibliojules_mobile/src/core/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

/// A miniature catalogue with the same shapes the real one uses: plain strings,
/// ``%(name)s`` placeholders, positional ``%s``/``%d`` and plural maps.
const _catalog = <String, dynamic>{
  'Catalog': 'Catálogo',
  'Sign in': 'Iniciar sesión',
  'About %(app)s': 'Acerca de %(app)s',
  'due %(date)s': 'vence %(date)s',
  'Added “%s”.': 'Se agregó «%s».',
  '%d book': {'one': '%d libro', 'other': '%d libros'},
  '%(count)s result for “%(query)s”': {
    'one': '%(count)s resultado para «%(query)s»',
    'other': '%(count)s resultados para «%(query)s»',
  },
  'Overdue': 'Atrasado',
};

void main() {
  final l10n = L10n('es-419', _catalog);
  final source = L10n('en', const {});

  group('normalizeLanguage', () {
    test('maps regional and legacy tags onto what we ship', () {
      expect(normalizeLanguage('es-419'), 'es-419');
      expect(normalizeLanguage('es_MX'), 'es-419');
      expect(normalizeLanguage('es-AR'), 'es-419');
      expect(normalizeLanguage('es'), 'es-419');
      expect(normalizeLanguage('en-US'), 'en');
      expect(normalizeLanguage('EN'), 'en');
      expect(normalizeLanguage('fr'), 'en');
      expect(normalizeLanguage(null), 'en');
      expect(normalizeLanguage('  '), 'en');
    });

    test('every shipped language is recognised', () {
      for (final option in kSupportedLanguages) {
        expect(normalizeLanguage(option.code), option.code);
        expect(isSupportedLanguage(option.code), isTrue);
      }
    });
  });

  group('localeFor', () {
    test('splits BCP-47 region codes', () {
      final locale = localeFor('es-419');
      expect(locale.languageCode, 'es');
      expect(locale.countryCode, '419');
      expect(localeFor('en').languageCode, 'en');
      expect(localeFor('en').countryCode, isNull);
    });
  });

  group('tr', () {
    test('translates and falls back to the source string', () {
      expect(l10n.tr('Catalog'), 'Catálogo');
      expect(l10n.tr('Nothing here'), 'Nothing here');
      expect(source.tr('Catalog'), 'Catalog');
    });

    test('fills %(name)s placeholders', () {
      expect(l10n.tr('About %(app)s', {'app': 'BiblioJules'}), 'Acerca de BiblioJules');
      expect(l10n.tr('due %(date)s', {'date': '2024-05-01'}), 'vence 2024-05-01');
    });

    test('leaves unknown placeholders alone', () {
      expect(l10n.tr('About %(app)s'), 'Acerca de %(app)s');
    });

    test('a plural entry read as a plain string uses the "other" form', () {
      expect(l10n.tr('%d book'), '%d libros');
    });
  });

  group('tf', () {
    test('fills positional placeholders', () {
      expect(l10n.tf('Added “%s”.', ['Dune']), 'Se agregó «Dune».');
      expect(source.tf('Added “%s”.', ['Dune']), 'Added “Dune”.');
    });
  });

  group('tn', () {
    test('picks the right plural form and fills the count', () {
      expect(l10n.tn('%d book', '%d books', 1), '1 libro');
      expect(l10n.tn('%d book', '%d books', 4), '4 libros');
    });

    test('handles named placeholders inside plural entries', () {
      final text = l10n.tn(
        '%(count)s result for “%(query)s”',
        '%(count)s results for “%(query)s”',
        3,
        {'query': 'dune'},
      );
      expect(text, '3 resultados para «dune»');
    });

    test('works with no catalogue at all', () {
      expect(source.tn('%d book', '%d books', 1), '1 book');
      expect(source.tn('%d book', '%d books', 2), '2 books');
    });
  });

  group('the real Spanish catalogue', () {
    test('is valid JSON with string or plural values', () {
      final raw = File('../app/locales/es-419.json').readAsStringSync();
      final decoded = json.decode(raw) as Map<String, dynamic>;
      expect(decoded, isNotEmpty);
      for (final entry in decoded.entries) {
        expect(
          entry.value is String || entry.value is Map,
          isTrue,
          reason: 'unexpected value for ${entry.key}',
        );
      }
      // Spot-check a few entries the mobile UI relies on.
      final real = L10n('es-419', decoded);
      expect(real.tr('Sign in'), 'Iniciar sesión');
      expect(real.tr('Settings'), 'Configuración');
    });
  });
}
