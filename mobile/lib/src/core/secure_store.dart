/// The bearer token, kept in the platform keystore.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kToken = 'auth_token';

  Future<String?> readToken() => _storage.read(key: _kToken);

  Future<void> writeToken(String? token) async {
    if (token == null || token.isEmpty) {
      await _storage.delete(key: _kToken);
      return;
    }
    await _storage.write(key: _kToken, value: token);
  }
}
