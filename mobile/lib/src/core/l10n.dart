/// Runtime string catalogue.
///
/// The Android app deliberately reuses the *same* catalogues as the web and
/// desktop editions (``app/locales/*.json``). English is the source language,
/// so the English string itself is the lookup key, and every other catalogue
/// maps that key onto a translation. Plural entries are stored as
/// ``{"one": …, "other": …}`` (mirroring Python's ``ngettext``).
///
/// Loading is done once at start-up for every shipped language (the files are
/// ~20 kB each), which keeps [tr] synchronous at every call site.
library;

import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:flutter/services.dart' show rootBundle;

/// A language the app ships a catalogue for.
class LanguageOption {
  const LanguageOption(this.code, this.label);

  /// BCP-47-ish code, matching the server's ``SUPPORTED_LANGUAGES``.
  final String code;

  /// The language's name *in that language* (used by the language switcher).
  final String label;
}

const List<LanguageOption> kSupportedLanguages = [
  LanguageOption('en', 'English'),
  LanguageOption('es-419', 'Español (Latinoamérica)'),
];

const String kDefaultLanguage = 'en';

/// Map any language tag (``es_MX``, ``es-AR``, ``en-US`` …) onto one of the
/// codes we ship. Mirrors ``app/i18n.normalize_language``.
String normalizeLanguage(String? code) {
  if (code == null || code.trim().isEmpty) return kDefaultLanguage;
  final tag = code.trim().toLowerCase().replaceAll('_', '-');
  if (tag == 'en' || tag == 'en-us') return 'en';
  if (tag == 'es-419') return 'es-419';
  final base = tag.split('-').first;
  if (base == 'en') return 'en';
  if (base == 'es') return 'es-419';
  return kDefaultLanguage;
}

/// True when [code] resolves to a language we have a catalogue for.
bool isSupportedLanguage(String? code) => normalizeLanguage(code) == code;

/// The [Locale] to hand to ``MaterialApp`` for one of our language codes
/// (``es-419`` is BCP-47, i.e. language ``es`` + region ``419``).
Locale localeFor(String code) {
  final parts = normalizeLanguage(code).split('-');
  return parts.length > 1 ? Locale(parts[0], parts[1]) : Locale(parts.first);
}

/// Locales declared to ``MaterialApp``, so Flutter's own widgets are
/// translated too.
const List<Locale> kSupportedLocales = [Locale('en'), Locale('es'), Locale('es', '419')];

class L10n {
  const L10n(this.language, this._catalog);

  /// Resolved language code.
  final String language;

  final Map<String, dynamic> _catalog;

  /// The bundled catalogue for [language]; the source language needs no file.
  static Future<L10n> load(String language) async {
    final code = normalizeLanguage(language);
    if (code == kDefaultLanguage) return L10n(code, const {});
    final raw = await rootBundle.loadString('assets/locales/$code.json');
    return L10n(code, json.decode(raw) as Map<String, dynamic>);
  }

  /// True when the strings are the untranslated English source.
  bool get isSourceLanguage => _catalog.isEmpty;

  /// Translate [source], filling ``%(name)s`` placeholders from [args].
  String tr(String source, [Map<String, Object?>? args]) =>
      _substitute(_lookup(source), args);

  /// Translate [source] and fill its positional ``%s``/``%d`` placeholders.
  String tf(String source, List<Object?> args) {
    var index = 0;
    return _lookup(source).replaceAllMapped(RegExp(r'%[sd]'), (match) {
      if (index >= args.length) return match.group(0)!;
      final value = args[index++];
      return value == null ? '' : '$value';
    });
  }

  /// Plural-aware lookup (``ngettext``): [n] picks the ``one``/``other`` form.
  ///
  /// Placeholders (``%(count)s``, ``%d``) are filled from [args] plus [n].
  String tn(
    String singular,
    String plural,
    int n, [
    Map<String, Object?>? args,
  ]) {
    final entry = _catalog[singular] ?? _catalog[plural];
    String text;
    if (entry is Map) {
      final chosen = n == 1 ? entry['one'] : entry['other'];
      text = chosen is String ? chosen : (n == 1 ? singular : plural);
    } else if (entry is String) {
      text = entry;
    } else {
      text = n == 1 ? singular : plural;
    }
    return _substitute(text, {'count': n, 'n': n, ...?args});
  }

  String _lookup(String source) {
    final value = _catalog[source];
    if (value is String) return value;
    if (value is Map) {
      // A plural entry read through the singular API: the "other" form reads
      // best on its own.
      final other = value['other'];
      if (other is String) return other;
    }
    return source;
  }

  String _substitute(String text, Map<String, Object?>? args) {
    if (!text.contains('%')) return text;
    var out = text;
    if (args != null && args.isNotEmpty) {
      out = out.replaceAllMapped(RegExp(r'%\((\w+)\)s'), (match) {
        final key = match.group(1)!;
        if (!args.containsKey(key)) return match.group(0)!;
        final value = args[key];
        return value == null ? '' : '$value';
      });
      out = out.replaceAllMapped(RegExp(r'%d'), (match) {
        final value = args['count'] ?? args['n'];
        return value == null ? match.group(0)! : '$value';
      });
    }
    return out;
  }
}

/// Every catalogue we ship, loaded once at start-up so lookups stay synchronous.
class CatalogCache {
  CatalogCache(this._byLanguage);

  final Map<String, L10n> _byLanguage;

  static Future<CatalogCache> preload() async {
    final loaded = <String, L10n>{};
    for (final option in kSupportedLanguages) {
      loaded[option.code] = await L10n.load(option.code);
    }
    return CatalogCache(loaded);
  }

  /// Force-load a language the app did not start with (used by tests).
  Future<L10n> ensure(String language) async {
    final code = normalizeLanguage(language);
    return _byLanguage[code] ??= await L10n.load(code);
  }

  L10n forLanguage(String language) {
    final code = normalizeLanguage(language);
    return _byLanguage[code] ??= L10n(code, const {});
  }

  List<LanguageOption> get options => kSupportedLanguages;
}
