/// Turns SQLite rows into the exact JSON shapes ``app/services/serializers.py``
/// hands out over HTTP.
///
/// This file is the reason the screens could stay untouched: the models
/// (``Book.fromJson`` and friends) parse *maps*, not rows, so as long as the
/// local store produces the same maps, every list, badge and detail page works
/// identically in both modes. Type fidelity matters — SQLite has no boolean, so
/// ``is_system`` arrives as ``0``/``1`` and must be turned back into a ``bool``,
/// or ``as bool`` in the model throws.
library;

/// ``YYYY-MM-DD HH:MM:SS.microseconds``: how SQLAlchemy writes a datetime to
/// SQLite, copied so an exported file is indistinguishable from a server one.
String sqliteDateTime(DateTime value) {
  final utc = value.toUtc();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}.'
      '${utc.microsecond.toString().padLeft(6, '0')}';
}

/// The timestamp to stamp on a row that is being written right now.
String nowStamp() => sqliteDateTime(DateTime.now().toUtc());

/// ``YYYY-MM-DD 12:00:00.000000`` -> ``YYYY-MM-DDTHH:MM:SS.000000``.
///
/// That is what ``datetime.isoformat()`` produces on the server. A value that is
/// not a stored datetime (already ISO, or empty) is passed through unchanged.
String isoDateTime(Object? stored) {
  final text = stored?.toString() ?? '';
  if (text.isEmpty) return '';
  return text.replaceFirst(' ', 'T');
}

/// ``YYYY-MM-DD`` for "today", the form dates are stored in.
String todayDate() {
  final now = DateTime.now();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}';
}

bool _asBool(Object? value) => value == 1 || value == true || value == '1';

/// One row of ``statuses`` -> ``status_to_dict``.
Map<String, dynamic> statusToJson(Map<String, Object?> row) => <String, dynamic>{
  'id': row['id'],
  'name': row['name'],
  'slug': row['slug'],
  'color': row['color'],
  'icon': row['icon'],
  'description': row['description'],
  'sort_order': row['sort_order'],
  'is_system': _asBool(row['is_system']),
  'is_default': _asBool(row['is_default']),
};

/// One row of ``locations`` -> ``location_to_dict``.
///
/// [fullPath] is computed by the caller (it needs the whole tree); the server
/// does the same walk in ``Location.full_path``.
Map<String, dynamic> locationToJson(
  Map<String, Object?> row, {
  required String fullPath,
}) => <String, dynamic>{
  'id': row['id'],
  'name': row['name'],
  'kind': row['kind'],
  'description': row['description'],
  'parent_id': row['parent_id'],
  'full_path': fullPath,
};

/// One row of ``loans`` -> ``loan_to_dict``.
Map<String, dynamic> loanToJson(Map<String, Object?> row) {
  final returnedAt = row['returned_at'] as String?;
  final dueAt = row['due_at'] as String?;
  final active = returnedAt == null;
  return <String, dynamic>{
    'id': row['id'],
    'book_id': row['book_id'],
    'borrower_name': row['borrower_name'],
    'borrower_contact': row['borrower_contact'],
    'lent_at': row['lent_at'],
    'due_at': dueAt,
    'returned_at': returnedAt,
    'is_active': active,
    // ISO dates compare correctly as strings, so "due before today" needs no
    // parsing — matching the server's ``due_at < date.today()``.
    'is_overdue': active && dueAt != null && dueAt.compareTo(todayDate()) < 0,
    'notes': row['notes'],
  };
}

/// A book row plus its relations -> ``book_to_dict``.
Map<String, dynamic> bookToJson(
  Map<String, Object?> row, {
  required List<String> authors,
  required String? publisher,
  required Map<String, dynamic>? location,
  required Map<String, dynamic>? status,
  required Map<String, dynamic>? activeLoan,
}) => <String, dynamic>{
  'id': row['id'],
  'isbn': row['isbn'],
  'title': row['title'],
  'subtitle': row['subtitle'],
  'authors': authors,
  'publisher': publisher,
  'published_date': row['published_date'],
  'published_year': row['published_year'],
  'description': row['description'],
  'page_count': row['page_count'],
  'language': row['language'],
  'cover_url': row['cover_url'],
  'cover_type': row['cover_type'],
  'read_status': row['read_status'],
  'score': row['score'],
  'saga': row['saga'],
  'saga_number': row['saga_number'],
  'source': row['source'],
  'notes': row['notes'],
  // The ids sit next to their nested objects, exactly as the API returns them,
  // so a client can preselect a dropdown without digging into the object.
  'location_id': row['location_id'],
  'status_id': row['status_id'],
  'location': location,
  'status': status,
  'active_loan': activeLoan,
  'created_at': isoDateTime(row['created_at']),
  'updated_at': isoDateTime(row['updated_at']),
};
