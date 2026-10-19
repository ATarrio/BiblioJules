import 'package:bibliojules_mobile/src/core/book_fields.dart';
import 'package:bibliojules_mobile/src/core/models/models.dart';
import 'package:bibliojules_mobile/src/core/util.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('orderedLocations', () {
    test('nests children under their parents, alphabetically', () {
      const locations = [
        Location(id: 1, name: 'Office'),
        Location(id: 2, name: 'Living room'),
        Location(id: 3, name: 'Shelf B', parentId: 1),
        Location(id: 4, name: 'Shelf A', parentId: 1),
        Location(id: 5, name: 'Box 1', parentId: 3),
      ];
      final ordered = orderedLocations(locations);
      expect(ordered.map((entry) => (entry.$1.name, entry.$2)).toList(), [
        ('Living room', 0),
        ('Office', 0),
        ('Shelf A', 1),
        ('Shelf B', 1),
        ('Box 1', 2),
      ]);
    });

    test('keeps a location whose parent is missing', () {
      const locations = [Location(id: 1, name: 'Orphan', parentId: 99)];
      final ordered = orderedLocations(locations);
      expect(ordered.single.$1.name, 'Orphan');
      expect(ordered.single.$2, 0);
    });

    test('survives a parent cycle without looping forever', () {
      const locations = [
        Location(id: 1, name: 'A', parentId: 2),
        Location(id: 2, name: 'B', parentId: 1),
      ];
      final ordered = orderedLocations(locations);
      expect(ordered.length, 2);
    });

    test('an empty library stays empty', () {
      expect(orderedLocations(const []), isEmpty);
    });
  });

  group('normalizeHexColor', () {
    test('accepts the shapes a user might type', () {
      expect(normalizeHexColor('#3366F2'), '#3366f2');
      expect(normalizeHexColor('3366f2'), '#3366f2');
      expect(normalizeHexColor('#abc'), '#aabbcc');
    });

    test('falls back on nonsense', () {
      expect(normalizeHexColor('not a colour'), '#64748b');
      expect(normalizeHexColor(''), '#64748b');
      expect(normalizeHexColor('#12345'), '#64748b');
    });
  });

  group('book vocabularies', () {
    test('cover types and read statuses match the server', () {
      expect(kCoverTypes.keys.toList(), [
        'hardcover',
        'paperback',
        'ebook',
        'audiobook',
        'pocket',
        'other',
      ]);
      expect(kReadStatuses.keys.toList(), [
        'unread',
        'to_read',
        'currently_reading',
        'read',
        'dnf',
      ]);
      expect(kScoreStep, 0.5);
      expect(kMinScore, 1.0);
      expect(kMaxScore, 5.0);
    });

    test('labels resolve, unknown slugs do not throw', () {
      expect(coverTypeLabel('paperback'), 'Paperback');
      expect(coverTypeLabel(null), '');
      expect(coverTypeLabel('nope'), '');
      expect(readStatusLabel('to_read'), 'To Be Read');
      expect(readStatusLabel('nope'), '');
    });
  });

  group('scoreStars', () {
    test('renders whole, half and empty stars', () {
      expect(scoreStars(null), '');
      expect(scoreStars(0), '');
      expect(scoreStars(1), '★☆☆☆☆');
      expect(scoreStars(3.5), '★★★½☆');
      expect(scoreStars(5), '★★★★★');
    });
  });

  group('normalizeIsbn', () {
    test('strips separators and upper-cases the X', () {
      expect(normalizeIsbn('978-0-441-01359-3'), '9780441013593');
      expect(normalizeIsbn('0 8044 2957 x'), '080442957X');
      expect(normalizeIsbn(''), '');
    });
  });
}
