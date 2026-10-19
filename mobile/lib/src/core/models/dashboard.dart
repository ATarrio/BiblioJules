import 'book.dart';
import 'loan.dart';
import 'status.dart';

/// Headline counters from ``GET /api/stats``.
class Stats {
  const Stats({
    this.total = 0,
    this.authors = 0,
    this.publishers = 0,
    this.loans = 0,
    this.wishlist = 0,
  });

  final int total;
  final int authors;
  final int publishers;
  final int loans;
  final int wishlist;

  factory Stats.fromJson(Map<String, dynamic> json) => Stats(
    total: (json['total'] as num?)?.toInt() ?? 0,
    authors: (json['authors'] as num?)?.toInt() ?? 0,
    publishers: (json['publishers'] as num?)?.toInt() ?? 0,
    loans: (json['loans'] as num?)?.toInt() ?? 0,
    wishlist: (json['wishlist'] as num?)?.toInt() ?? 0,
  );
}

/// One row of the "books per status" summary.
class StatusCount {
  const StatusCount({required this.status, required this.count});

  final Status status;
  final int count;

  factory StatusCount.fromJson(Map<String, dynamic> json) => StatusCount(
    status: Status.fromJson(json['status'] as Map<String, dynamic>),
    count: (json['count'] as num?)?.toInt() ?? 0,
  );
}

/// Everything ``GET /api/dashboard`` returns, in one object.
class DashboardData {
  const DashboardData({
    required this.stats,
    this.statusCounts = const [],
    this.recent = const [],
    this.activeLoans = const [],
  });

  final Stats stats;
  final List<StatusCount> statusCounts;
  final List<Book> recent;
  final List<LoanWithBook> activeLoans;

  factory DashboardData.fromJson(Map<String, dynamic> json) {
    return DashboardData(
      stats: Stats.fromJson((json['stats'] ?? const {}) as Map<String, dynamic>),
      statusCounts:
          (json['status_counts'] as List?)
              ?.map((e) => StatusCount.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      recent:
          (json['recent'] as List?)
              ?.map((e) => Book.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      activeLoans:
          (json['active_loans'] as List?)
              ?.map((e) => LoanWithBook.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}

/// A catalogue search result from the online lookup (Open Library / Google
/// Books), i.e. ``GET /api/search``.
class SearchResult {
  const SearchResult({
    required this.title,
    this.authors = const [],
    this.isbn,
    this.publisher,
    this.publishedDate,
    this.pageCount,
    this.language,
    this.coverUrl,
    this.description,
    this.source,
  });

  final String title;
  final List<String> authors;
  final String? isbn;
  final String? publisher;
  final String? publishedDate;
  final int? pageCount;
  final String? language;
  final String? coverUrl;
  final String? description;
  final String? source;

  String get authorsDisplay => authors.isEmpty ? 'Unknown author' : authors.join(', ');

  factory SearchResult.fromJson(Map<String, dynamic> json) {
    final authors = json['authors'];
    return SearchResult(
      title: (json['title'] ?? '') as String,
      authors: authors is List
          ? authors.map((e) => '$e').toList()
          : (json['authors_str'] == null
                ? const <String>[]
                : '${json['authors_str']}'
                      .split(',')
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toList()),
      isbn: json['isbn'] as String?,
      publisher: json['publisher'] as String?,
      publishedDate: json['published_date'] as String?,
      pageCount: (json['page_count'] as num?)?.toInt(),
      language: json['language'] as String?,
      coverUrl: json['cover_url'] as String?,
      description: json['description'] as String?,
      source: json['source'] as String?,
    );
  }

  /// The fields a new book should inherit, as an API payload.
  Map<String, dynamic> toBookPayload() {
    final payload = <String, dynamic>{
      'title': title,
      'authors': authors,
      'isbn': isbn,
      'publisher': publisher,
      'published_date': publishedDate,
      'page_count': pageCount,
      'language': language,
      'cover_url': coverUrl,
      'description': description,
    };
    if (source != null) payload['source'] = source;
    return payload;
  }
}
