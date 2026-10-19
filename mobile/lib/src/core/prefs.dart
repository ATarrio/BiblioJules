/// Small, non-secret settings stored with ``shared_preferences``.
///
/// The bearer token deliberately lives in the platform keystore instead (see
/// [SecureStore]); everything here is a preference the user could read anyway.
library;

import 'dart:ui' show PlatformDispatcher;

import 'package:shared_preferences/shared_preferences.dart';

import 'l10n.dart';

class AppPrefs {
  AppPrefs(this._prefs);

  final SharedPreferences _prefs;

  static const _kBaseUrl = 'backend_url';
  static const _kLanguage = 'language';
  static const _kUsername = 'account_username';
  static const _kSort = 'catalog_sort';
  static const _kDirection = 'catalog_dir';

  static Future<AppPrefs> load() async {
    return AppPrefs(await SharedPreferences.getInstance());
  }

  /// The library server the app points at, or ``null`` before it is set.
  String? get baseUrl {
    final value = _prefs.getString(_kBaseUrl);
    return (value == null || value.trim().isEmpty) ? null : value;
  }

  Future<void> setBaseUrl(String? url) async {
    if (url == null || url.trim().isEmpty) {
      await _prefs.remove(_kBaseUrl);
      return;
    }
    await _prefs.setString(_kBaseUrl, url);
  }

  /// The chosen UI language, or ``null`` to follow the device.
  String? get language {
    final value = _prefs.getString(_kLanguage);
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> setLanguage(String? code) async {
    if (code == null || code.isEmpty) {
      await _prefs.remove(_kLanguage);
      return;
    }
    await _prefs.setString(_kLanguage, normalizeLanguage(code));
  }

  /// The language to use right now: the override, else the device's.
  String get effectiveLanguage => normalizeLanguage(language ?? deviceLanguage());

  /// The username to prefill on the sign-in screen.
  String? get username => _prefs.getString(_kUsername);

  Future<void> setUsername(String? username) async {
    if (username == null || username.isEmpty) {
      await _prefs.remove(_kUsername);
      return;
    }
    await _prefs.setString(_kUsername, username);
  }

  /// Last catalog ordering, so reopening the app feels like coming back.
  String get sort => _prefs.getString(_kSort) ?? 'recent';

  String? get direction => _prefs.getString(_kDirection);

  Future<void> setSort(String sort, String? direction) async {
    await _prefs.setString(_kSort, sort);
    if (direction == null || direction.isEmpty) {
      await _prefs.remove(_kDirection);
    } else {
      await _prefs.setString(_kDirection, direction);
    }
  }
}

/// The device's preferred language, normalised onto one we ship.
String deviceLanguage() {
  try {
    // ``Locale.languageCode`` alone loses the region, but ``toLanguageTag``
    // gives us "es-MX"/"en-US", which [normalizeLanguage] understands.
    for (final locale in PlatformDispatcher.instance.locales) {
      final normalized = normalizeLanguage(locale.toLanguageTag());
      if (isSupportedLanguage(normalized)) return normalized;
    }
    return normalizeLanguage(PlatformDispatcher.instance.locale.toLanguageTag());
  } catch (_) {
    return kDefaultLanguage;
  }
}
