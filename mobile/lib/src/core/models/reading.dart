/// Personal reading stats, goals and the want-to-read list.
///
/// These come from ``GET /api/personal-stats``, ``GET /api/goals`` and
/// ``GET /api/wantlist`` on a server. In local mode the same shapes are built
/// from the SQLite file plus two small JSON files on the device.
library;

/// Headline figures computed from the catalogue.
class ReadingStats {
  const ReadingStats({
    this.totalBooks = 0,
    this.inLibrary = 0,
    this.booksRead = 0,
    this.pagesRead = 0,
    this.avgRating,
    this.currentlyReading = 0,
    this.loans = 0,
    this.wishlist = 0,
    this.authors = 0,
    this.statusBreakdown = const {},
  });

  final int totalBooks;
  final int inLibrary;
  final int booksRead;
  final int pagesRead;
  final double? avgRating;
  final int currentlyReading;
  final int loans;
  final int wishlist;
  final int authors;
  final Map<String, int> statusBreakdown;

  int breakdown(String key) => statusBreakdown[key] ?? 0;

  int get lostOrDonated => breakdown('lost') + breakdown('donated');

  factory ReadingStats.fromJson(Map<String, dynamic> json) {
    final raw = json['status_breakdown'];
    return ReadingStats(
      totalBooks: (json['total_books'] as num?)?.toInt() ?? 0,
      inLibrary: (json['in_library'] as num?)?.toInt() ?? 0,
      booksRead: (json['books_read'] as num?)?.toInt() ?? 0,
      pagesRead: (json['pages_read'] as num?)?.toInt() ?? 0,
      avgRating: (json['avg_rating'] as num?)?.toDouble(),
      currentlyReading: (json['currently_reading'] as num?)?.toInt() ?? 0,
      loans: (json['loans'] as num?)?.toInt() ?? 0,
      wishlist: (json['wishlist'] as num?)?.toInt() ?? 0,
      authors: (json['authors'] as num?)?.toInt() ?? 0,
      statusBreakdown: raw is Map
          ? {
              for (final entry in raw.entries)
                '${entry.key}': (entry.value as num?)?.toInt() ?? 0,
            }
          : const {},
    );
  }
}

/// A yearly reading objective. Zero means "not set"; a null year means "any
/// year". Progress is tracked per objective (``booksDone`` / ``pagesDone``),
/// bumped whenever a book is marked read in this objective's year — never the
/// all-time count of read books, which stays on the dashboard.
class ReadingGoals {
  const ReadingGoals({
    this.year,
    this.targetBooks = 0,
    this.targetPages = 0,
    this.booksDone = 0,
    this.pagesDone = 0,
  });

  final int? year;
  final int targetBooks;
  final int targetPages;
  final int booksDone;
  final int pagesDone;

  factory ReadingGoals.fromJson(Map<String, dynamic> json) => ReadingGoals(
    year: (json['year'] as num?)?.toInt(),
    targetBooks: (json['target_books'] as num?)?.toInt() ?? 0,
    targetPages: (json['target_pages'] as num?)?.toInt() ?? 0,
    booksDone: (json['books_done'] as num?)?.toInt() ?? 0,
    pagesDone: (json['pages_done'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'year': year,
    'target_books': targetBooks,
    'target_pages': targetPages,
    'books_done': booksDone,
    'pages_done': pagesDone,
  };
}

/// One book on the want-to-read list.
class WantEntry {
  const WantEntry({
    required this.id,
    required this.title,
    this.isbn,
    this.authors = '',
    this.publisher,
    this.notes = '',
    this.addedAt,
  });

  final String id;
  final String title;
  final String? isbn;
  final String authors;
  final String? publisher;
  final String notes;
  final String? addedAt;

  factory WantEntry.fromJson(Map<String, dynamic> json) {
    final authors = json['authors'];
    return WantEntry(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? ''}',
      isbn: json['isbn'] as String?,
      authors: authors is List
          ? authors.map((name) => '$name').join(', ')
          : '${authors ?? ''}',
      publisher: json['publisher'] as String?,
      notes: '${json['notes'] ?? ''}',
      addedAt: json['added_at'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'isbn': isbn,
    'authors': authors,
    'publisher': publisher,
    'notes': notes,
    'added_at': addedAt,
  };
}
