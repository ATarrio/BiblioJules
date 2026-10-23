/// The bearer token, kept in the platform keystore.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kToken = 'auth_token';

  /// Read the token, treating an unavailable keystore as "not signed in".
  ///
  /// A locked or corrupted keystore used to crash the app at start-up. Falling
  /// back to `null` is safe: the worst case is one extra sign-in.
  Future<String?> readToken() async {
    try {
      return await _storage.read(key: _kToken);
    } catch (_) {
      return null;
    }
  }

  /// Persist the token. A keystore failure must not abort an otherwise valid
  /// sign-in; the session still works from memory until the app restarts.
  Future<void> writeToken(String? token) async {
    try {
      if (token == null || token.isEmpty) {
        await _storage.delete(key: _kToken);
      } else {
        await _storage.write(key: _kToken, value: token);
      }
    } catch (_) {
      // See the class comment: an unavailable keystore is not fatal.
    }
  }
}
