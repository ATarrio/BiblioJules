import 'package:bibliojules_mobile/src/core/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Book.fromJson', () {
    final json = <String, dynamic>{
      'id': 7,
      'isbn': '9780441013593',
      'title': 'Dune',
      'subtitle': 'Book One',
      'authors': ['Frank Herbert'],
      'publisher': 'Ace',
      'published_date': '1965',
      'published_year': 1965,
      'description': 'Sand.',
      'page_count': 412,
      'language': 'eng',
      'cover_url': 'https://example.test/dune.jpg',
      'cover_type': 'paperback',
      'read_status': 'read',
      'score': 4.5,
      'saga': 'Dune',
      'saga_number': 1,
      'source': 'openlibrary',
      'notes': 'Signed copy',
      'location_id': 3,
      'status_id': 2,
      'location': {'id': 3, 'name': 'Shelf A', 'full_path': 'Office › Shelf A'},
      'status': {'id': 2, 'name': 'Owned', 'color': '#3366f2', 'is_default': true},
      'active_loan': {
        'id': 9,
        'book_id': 7,
        'borrower_name': 'Ana',
        'lent_at': '2024-05-01',
        'due_at': '2024-05-20',
        'is_active': true,
        'is_overdue': true,
      },
      'created_at': '2024-01-01T10:00:00+00:00',
      'updated_at': '2024-02-01T10:00:00+00:00',
    };

    test('maps every field', () {
      final book = Book.fromJson(json);
      expect(book.id, 7);
      expect(book.title, 'Dune');
      expect(book.authors, ['Frank Herbert']);
      expect(book.publishedDate, '1965');
      expect(book.publishedYear, 1965);
      expect(book.score, 4.5);
      expect(book.saga, 'Dune');
      expect(book.sagaNumber, 1);
      expect(book.location?.display, 'Office › Shelf A');
      expect(book.status?.name, 'Owned');
      expect(book.status?.isDefault, isTrue);
      expect(book.activeLoan?.borrowerName, 'Ana');
      expect(book.activeLoan?.isOverdue, isTrue);
      expect(book.isLoaned, isTrue);
    });

    test('tolerates a response with only the required fields', () {
      final book = Book.fromJson(<String, dynamic>{'id': 1, 'title': 'Bare'});
      expect(book.title, 'Bare');
      expect(book.authors, isEmpty);
      expect(book.activeLoan, isNull);
      expect(book.isLoaned, isFalse);
      expect(book.authorDisplay, 'Unknown author');
    });
  });

  group('Book.toPayload', () {
    test('sends nulls so the form can clear a value', () {
      const book = Book(id: 7, title: 'Dune', authors: ['Frank Herbert']);
      final payload = book.toPayload();
      expect(payload['title'], 'Dune');
      expect(payload['authors'], ['Frank Herbert']);
      expect(payload.containsKey('score'), isTrue);
      expect(payload['score'], isNull);
      expect(payload['location_id'], isNull);
    });

    test('echoes source only when the book had one', () {
      const without = Book(id: 1, title: 'A');
      expect(without.toPayload().containsKey('source'), isFalse);
      const withSource = Book(id: 1, title: 'A', source: 'manual');
      expect(withSource.toPayload()['source'], 'manual');
    });
  });

  group('SearchResult.fromJson', () {
    test('reads a list of authors', () {
      final result = SearchResult.fromJson({
        'title': 'Dune',
        'authors': ['Frank Herbert'],
        'isbn': '9780441013593',
        'source': 'openlibrary',
      });
      expect(result.authors, ['Frank Herbert']);
      expect(result.authorsDisplay, 'Frank Herbert');
      expect(result.toBookPayload()['source'], 'openlibrary');
    });

    test('falls back to the flattened authors_str form', () {
      final result = SearchResult.fromJson({
        'title': 'Dune',
        'authors_str': 'Frank Herbert, Brian Herbert',
      });
      expect(result.authors, ['Frank Herbert', 'Brian Herbert']);
    });

    test('an unknown author reads sensibly', () {
      final result = SearchResult.fromJson({'title': 'Dune'});
      expect(result.authorsDisplay, 'Unknown author');
    });
  });

  group('Status.defaultOf', () {
    test('finds the default shelf', () {
      const statuses = [
        Status(id: 1, name: 'Wishlist'),
        Status(id: 2, name: 'Owned', isDefault: true),
      ];
      expect(Status.defaultOf(statuses)?.name, 'Owned');
      expect(Status.defaultOf([const Status(id: 1, name: 'Only')]), isNull);
    });
  });

  group('DashboardData.fromJson', () {
    test('parses stats, counts, recent books and loans', () {
      final data = DashboardData.fromJson({
        'stats': {'total': 12, 'authors': 4, 'publishers': 3, 'loans': 1, 'wishlist': 5},
        'status_counts': [
          {
            'status': {'id': 1, 'name': 'Owned', 'color': '#3366f2'},
            'count': 7,
          },
        ],
        'recent': [
          {'id': 1, 'title': 'Dune'},
        ],
        'active_loans': [
          {
            'id': 4,
            'book_id': 1,
            'borrower_name': 'Ana',
            'is_active': true,
            'is_overdue': false,
            'book': {'id': 1, 'title': 'Dune'},
          },
        ],
      });
      expect(data.stats.total, 12);
      expect(data.statusCounts.single.count, 7);
      expect(data.recent.single.title, 'Dune');
      expect(data.activeLoans.single.bookTitle, 'Dune');
      expect(data.activeLoans.single.loan.borrowerName, 'Ana');
    });
  });
}
