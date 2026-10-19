/// A signed-in account. Never carries a password or a token hash.
class User {
  const User({
    required this.id,
    required this.username,
    this.displayName,
    this.label,
    this.role = 'member',
    this.isAdmin = false,
    this.isActive = true,
    this.createdAt,
    this.lastLoginAt,
  });

  final int id;
  final String username;
  final String? displayName;
  final String? label;

  /// ``admin`` or ``member``.
  final String role;
  final bool isAdmin;
  final bool isActive;
  final String? createdAt;
  final String? lastLoginAt;

  /// What to show in the UI: the display name when there is one.
  String get shown => (displayName != null && displayName!.isNotEmpty)
      ? displayName!
      : username;

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: (json['id'] as num).toInt(),
      username: (json['username'] ?? '') as String,
      displayName: json['display_name'] as String?,
      label: json['label'] as String?,
      role: (json['role'] ?? 'member') as String,
      isAdmin: (json['is_admin'] ?? false) as bool,
      isActive: (json['is_active'] ?? true) as bool,
      createdAt: json['created_at'] as String?,
      lastLoginAt: json['last_login_at'] as String?,
    );
  }
}

/// The response of ``POST /api/auth/login``.
class LoginResult {
  const LoginResult({required this.token, required this.user, this.expiresAt});

  final String token;
  final User user;
  final String? expiresAt;

  factory LoginResult.fromJson(Map<String, dynamic> json) {
    return LoginResult(
      token: (json['token'] ?? '') as String,
      user: User.fromJson(json['user'] as Map<String, dynamic>),
      expiresAt: json['expires_at'] as String?,
    );
  }
}
