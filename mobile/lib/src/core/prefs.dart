/// Small, non-secret settings stored with ``shared_preferences``.
///
/// The bearer token deliberately lives in the platform keystore instead (see
/// [SecureStore]); everything here is a preference the user could read anyway.
library;

import 'dart:ui' show PlatformDispatcher;

import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import 'l10n.dart';

/// Where the app's catalogue comes from.
///
/// Both modes are first-class: local mode is a whole library in a file on the
/// phone (see ``LocalRepo``), server mode is the shared library on a host. The
/// default is [server], so an installation that predates local mode keeps
/// behaving exactly as it did.
enum LibraryMode {
  local,
  server,
}

class AppPrefs {
  AppPrefs(this._prefs);

  final SharedPreferences _prefs;

  static const _kBaseUrl = 'backend_url';
  static const _kLanguage = 'language';
  static const _kUsername = 'account_username';
  static const _kSort = 'catalog_sort';
  static const _kDirection = 'catalog_dir';
  static const _kMode = 'library_mode';
  static const _kLocalLibrary = 'local_library_name';
  static const _kColorTheme = 'color_theme';
  static const _kSyncFolder = 'sync_folder_uri';
  static const _kSyncFolderName = 'sync_folder_name';
  static const _kSyncOnStart = 'sync_on_start';

  static Future<AppPrefs> load() async {
    return AppPrefs(await SharedPreferences.getInstance());
  }

  /// Where the catalogue is read from. Defaults to [LibraryMode.server].
  LibraryMode get mode =>
      _prefs.getString(_kMode) == 'local' ? LibraryMode.local : LibraryMode.server;

  Future<void> setMode(LibraryMode mode) async {
    if (mode == LibraryMode.server) {
      await _prefs.remove(_kMode);
      return;
    }
    await _prefs.setString(_kMode, 'local');
  }

  /// The name the user gave the on-device library, or ``null`` when it has
  /// never been named. The name doubles as the file name (slugified).
  String? get localLibraryName {
    final value = _prefs.getString(_kLocalLibrary);
    return (value == null || value.trim().isEmpty) ? null : value;
  }

  Future<void> setLocalLibraryName(String? name) async {
    if (name == null || name.trim().isEmpty) {
      await _prefs.remove(_kLocalLibrary);
      return;
    }
    await _prefs.setString(_kLocalLibrary, name.trim());
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

  /// The accent colour the UI is drawn in, as a known theme slug.
  String get colorTheme => normalizeThemeSlug(_prefs.getString(_kColorTheme));

  Future<void> setColorTheme(String slug) async {
    await _prefs.setString(_kColorTheme, normalizeThemeSlug(slug));
  }

  /// The folder snapshots are exchanged through, as an Android tree URI.
  ///
  /// Only the local library syncs this way; the hosted server has its own
  /// folder, managed from its admin page.
  String? get syncFolderUri {
    final value = _prefs.getString(_kSyncFolder);
    return (value == null || value.isEmpty) ? null : value;
  }

  /// What that folder is called, so the settings screen can name it.
  String? get syncFolderName {
    final value = _prefs.getString(_kSyncFolderName);
    return (value == null || value.trim().isEmpty) ? null : value;
  }

  Future<void> setSyncFolder(String? uri, {String? name}) async {
    if (uri == null || uri.isEmpty) {
      await _prefs.remove(_kSyncFolder);
      await _prefs.remove(_kSyncFolderName);
      return;
    }
    await _prefs.setString(_kSyncFolder, uri);
    if (name == null || name.trim().isEmpty) {
      await _prefs.remove(_kSyncFolderName);
    } else {
      await _prefs.setString(_kSyncFolderName, name.trim());
    }
  }

  /// Whether a sync runs once when the app starts.
  bool get syncOnStart => _prefs.getBool(_kSyncOnStart) ?? false;

  Future<void> setSyncOnStart(bool value) async {
    if (value) {
      await _prefs.setBool(_kSyncOnStart, true);
      return;
    }
    await _prefs.remove(_kSyncOnStart);
  }

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
