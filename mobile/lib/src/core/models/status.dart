/// A reading status (owned, wishlist, borrowed …) — the user-editable labels
/// that sit alongside the fixed read-status vocabulary.
class Status {
  const Status({
    required this.id,
    required this.name,
    this.slug,
    this.color,
    this.icon,
    this.description,
    this.sortOrder = 0,
    this.isSystem = false,
    this.isDefault = false,
  });

  final int id;
  final String name;
  final String? slug;
  final String? color;
  final String? icon;
  final String? description;
  final int sortOrder;
  final bool isSystem;
  final bool isDefault;

  factory Status.fromJson(Map<String, dynamic> json) {
    return Status(
      id: (json['id'] as num).toInt(),
      name: (json['name'] ?? '') as String,
      slug: json['slug'] as String?,
      color: json['color'] as String?,
      icon: json['icon'] as String?,
      description: json['description'] as String?,
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      isSystem: (json['is_system'] ?? false) as bool,
      isDefault: (json['is_default'] ?? false) as bool,
    );
  }

  /// The default status, as chosen by the server.
  static Status? defaultOf(Iterable<Status> statuses) {
    for (final status in statuses) {
      if (status.isDefault) return status;
    }
    return null;
  }
}
