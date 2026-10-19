import 'loan.dart';
import 'location.dart';
import 'status.dart';

/// A catalogue entry.
///
/// Mirrors ``book_to_dict`` in the server. Everything except [id] and [title] is
/// optional: the server accepts partial writes and hand-added books have very
/// little metadata.
class Book {
  const Book({
    required this.id,
    required this.title,
    this.isbn,
    this.subtitle,
    this.authors = const [],
    this.publisher,
    this.publishedDate,
    this.publishedYear,
    this.description,
    this.pageCount,
    this.language,
    this.coverUrl,
    this.coverType,
    this.readStatus,
    this.score,
    this.saga,
    this.sagaNumber,
    this.source,
    this.notes,
    this.locationId,
    this.statusId,
    this.location,
    this.status,
    this.activeLoan,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final String title;
  final String? isbn;
  final String? subtitle;
  final List<String> authors;
  final String? publisher;

  /// Whatever fraction of a date the catalogue knows: ``2019``, ``2019-04`` or
  /// ``2019-04-23``. Kept as a string because that is how it is stored.
  final String? publishedDate;

  /// Read-only projection of [publishedDate], filled in by the server.
  final int? publishedYear;
  final String? description;
  final int? pageCount;
  final String? language;
  final String? coverUrl;
  final String? coverType;
  final String? readStatus;
  final double? score;
  final String? saga;
  final int? sagaNumber;
  final String? source;
  final String? notes;
  final int? locationId;
  final int? statusId;
  final Location? location;
  final Status? status;
  final Loan? activeLoan;
  final String? createdAt;
  final String? updatedAt;

  bool get isLoaned => activeLoan != null;

  /// "Unknown author" when we have nothing, mirroring the server's label.
  String get authorDisplay =>
      authors.isEmpty ? 'Unknown author' : authors.join(', ');

  factory Book.fromJson(Map<String, dynamic> json) {
    return Book(
      id: (json['id'] as num).toInt(),
      title: (json['title'] ?? '') as String,
      isbn: json['isbn'] as String?,
      subtitle: json['subtitle'] as String?,
      authors: (json['authors'] as List?)?.map((e) => '$e').toList() ?? const [],
      publisher: json['publisher'] as String?,
      publishedDate: json['published_date'] as String?,
      publishedYear: (json['published_year'] as num?)?.toInt(),
      description: json['description'] as String?,
      pageCount: (json['page_count'] as num?)?.toInt(),
      language: json['language'] as String?,
      coverUrl: json['cover_url'] as String?,
      coverType: json['cover_type'] as String?,
      readStatus: json['read_status'] as String?,
      score: (json['score'] as num?)?.toDouble(),
      saga: json['saga'] as String?,
      sagaNumber: (json['saga_number'] as num?)?.toInt(),
      source: json['source'] as String?,
      notes: json['notes'] as String?,
      locationId: (json['location_id'] as num?)?.toInt(),
      statusId: (json['status_id'] as num?)?.toInt(),
      location: json['location'] == null
          ? null
          : Location.fromJson(json['location'] as Map<String, dynamic>),
      status: json['status'] == null
          ? null
          : Status.fromJson(json['status'] as Map<String, dynamic>),
      activeLoan: json['active_loan'] == null
          ? null
          : Loan.fromJson(json['active_loan'] as Map<String, dynamic>),
      createdAt: json['created_at'] as String?,
      updatedAt: json['updated_at'] as String?,
    );
  }

  /// The write payload for ``POST /api/books`` / ``PUT /api/books/{id}``.
  ///
  /// Nulls are sent deliberately: the API treats a field that is *present* as
  /// authoritative, which is how the form clears a value. [source] is the one
  /// field the form never edits, so it is only echoed back when it was set.
  Map<String, dynamic> toPayload() {
    final payload = <String, dynamic>{
      'isbn': isbn,
      'title': title,
      'subtitle': subtitle,
      'authors': authors,
      'publisher': publisher,
      'published_date': publishedDate,
      'description': description,
      'page_count': pageCount,
      'language': language,
      'cover_url': coverUrl,
      'cover_type': coverType,
      'read_status': readStatus,
      'score': score,
      'saga': saga,
      'saga_number': sagaNumber,
      'location_id': locationId,
      'status_id': statusId,
      'notes': notes,
    };
    if (source != null) payload['source'] = source;
    return payload;
  }

  Book copyWith({
    String? Function()? title,
    String? Function()? isbn,
    String? Function()? subtitle,
    List<String>? authors,
    String? Function()? publisher,
    String? Function()? publishedDate,
    String? Function()? description,
    int? Function()? pageCount,
    String? Function()? language,
    String? Function()? coverUrl,
    String? Function()? coverType,
    String? Function()? readStatus,
    double? Function()? score,
    String? Function()? saga,
    int? Function()? sagaNumber,
    String? Function()? notes,
    int? Function()? locationId,
    int? Function()? statusId,
    String? source,
  }) {
    return Book(
      id: id,
      title: title?.call() ?? this.title,
      isbn: isbn?.call() ?? this.isbn,
      subtitle: subtitle?.call() ?? this.subtitle,
      authors: authors ?? this.authors,
      publisher: publisher?.call() ?? this.publisher,
      publishedDate: publishedDate?.call() ?? this.publishedDate,
      publishedYear: publishedYear,
      description: description?.call() ?? this.description,
      pageCount: pageCount?.call() ?? this.pageCount,
      language: language?.call() ?? this.language,
      coverUrl: coverUrl?.call() ?? this.coverUrl,
      coverType: coverType?.call() ?? this.coverType,
      readStatus: readStatus?.call() ?? this.readStatus,
      score: score?.call() ?? this.score,
      saga: saga?.call() ?? this.saga,
      sagaNumber: sagaNumber?.call() ?? this.sagaNumber,
      source: source ?? this.source,
      notes: notes?.call() ?? this.notes,
      locationId: locationId?.call() ?? this.locationId,
      statusId: statusId?.call() ?? this.statusId,
      location: location,
      status: status,
      activeLoan: activeLoan,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  /// A blank book for the "add" form.
  static const Book empty = Book(id: 0, title: '');
}
