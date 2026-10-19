/// A bare ``{id, name}`` pair (authors and publishers).
class RefItem {
  const RefItem({required this.id, required this.name});

  final int id;
  final String name;

  factory RefItem.fromJson(Map<String, dynamic> json) => RefItem(
    id: (json['id'] as num).toInt(),
    name: (json['name'] ?? '') as String,
  );
}
