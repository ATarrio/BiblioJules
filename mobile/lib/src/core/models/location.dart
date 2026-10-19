/// A shelf / room / box in the physical library.
class Location {
  const Location({
    required this.id,
    required this.name,
    this.kind,
    this.description,
    this.parentId,
    this.fullPath,
  });

  final int id;
  final String name;
  final String? kind;
  final String? description;
  final int? parentId;

  /// Server-computed "Living room › Shelf B" style path.
  final String? fullPath;

  factory Location.fromJson(Map<String, dynamic> json) {
    return Location(
      id: (json['id'] as num).toInt(),
      name: (json['name'] ?? '') as String,
      kind: json['kind'] as String?,
      description: json['description'] as String?,
      parentId: (json['parent_id'] as num?)?.toInt(),
      fullPath: json['full_path'] as String?,
    );
  }

  String get display => (fullPath == null || fullPath!.isEmpty) ? name : fullPath!;
}
