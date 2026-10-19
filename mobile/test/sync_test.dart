/// Sharing one library across two devices, on a desktop.
///
/// The scenario is the same one ``app/services/sync.py`` is checked against in
/// Python (``/tmp/opencode/verify_sync.py``): two independent SQLite files, one
/// shared folder, and the rules of the merge — first-contact dedupe,
/// newest-edit-wins, deletes travelling as tombstones and a later edit bringing
/// a deleted row back.
library;

import 'dart:io';

import 'package:bibliojules_mobile/src/local/local_repo.dart';
import 'package:bibliojules_mobile/src/local/schema.dart';
import 'package:bibliojules_mobile/src/local/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

LocalRepo _repoIn(Directory dir) =>
    LocalRepo(documentsDirectory: () async => dir);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory root;
  late Directory dirA;
  late Directory dirB;
  late Directory shared;
  late Directory scratch;
  late LocalRepo repoA;
  late LocalRepo repoB;

  LibrarySync syncOf(LocalRepo repo, [Directory? folder]) => LibrarySync(
    repo: repo,
    transport: FolderSyncTransport(folder ?? shared),
    scratchDirectory: () async => scratch,
  );

  /// A query against a closed file, for assertions the repo cannot express.
  Future<List<Map<String, Object?>>> rows(String path, String sql) async {
    final db = await openDatabase(path, readOnly: true, singleInstance: false);
    try {
      return await db.rawQuery(sql);
    } finally {
      await db.close();
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bibliojules_sync');
    dirA = Directory('${root.path}/a')..createSync();
    dirB = Directory('${root.path}/b')..createSync();
    shared = Directory('${root.path}/shared')..createSync();
    scratch = Directory('${root.path}/scratch')..createSync();
    // B first: its seeded statuses then predate A's, so the statuses A publishes
    // are the newer ones and B has genuinely nothing to say after the merge.
    repoB = _repoIn(dirB);
    await repoB.open('B library');
    repoA = _repoIn(dirA);
    await repoA.open('A library');
  });

  tearDown(() async {
    await repoA.dispose();
    await repoB.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('the first sync publishes the library as a snapshot', () async {
    final room = await repoA.createLocation(name: 'Living room', kind: 'Room');
    final shelf = await repoA.createLocation(
      name: 'Shelf A',
      parentId: room.id,
      kind: 'Shelf',
    );
    final book = await repoA.createBook({
      'title': 'Dune',
      'authors': ['Frank Herbert'],
      'publisher': 'Chilton',
      'isbn': '9780441013593',
      'published_year': '1965',
      'location_id': shelf.id,
    });
    await repoA.lendBook(book.id, borrowerName: 'Ada');

    final result = await syncOf(repoA).run();
    expect(result.pushed, isTrue);
    expect(result.mergedSnapshot, isFalse);

    final snapshot = File(
      '${shared.path}${Platform.pathSeparator}$kSnapshotName',
    );
    expect(snapshot.existsSync(), isTrue);
    final meta = await readSnapshotMeta(snapshot);
    expect(meta.generation, 1);
    expect(meta.format, kSyncFormat);
    expect(meta.deviceName, isNotEmpty);
    expect(meta.rowCounts['books'], 1);

    final tables = await rows(
      snapshot.path,
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final names = tables.map((row) => '${row['name']}').toSet();
    expect(names.contains('users'), isFalse);
    expect(names.contains('tokens'), isFalse);
    expect(names.contains('sync_meta'), isTrue);
  });

  test('the second device merges the snapshot and keeps one of everything', () async {
    final book = await repoA.createBook({
      'title': 'Dune',
      'authors': ['Frank Herbert'],
      'publisher': 'Chilton',
    });
    await syncOf(repoA).run();

    final merged = await syncOf(repoB).run();
    expect(merged.mergedSnapshot, isTrue);
    expect(merged.merge, isNotNull);
    expect(merged.merge!.added['books'], 1);
    expect((await repoB.listBooks()).single.title, 'Dune');
    expect((await repoB.listStatuses()).length, 6);
    expect((await repoB.listAuthors()).single.name, 'Frank Herbert');
    expect((await repoB.listPublishers()).single.name, 'Chilton');
    expect(merged.pushed, isFalse, reason: 'B observed, it did not invent');

    // Both devices now agree on the status identities, so neither will keep
    // rewriting the snapshot.
    final statusesA = await rows(
      repoA.databasePath!,
      'SELECT sync_id FROM statuses',
    );
    final statusesB = await rows(
      repoB.databasePath!,
      'SELECT sync_id FROM statuses',
    );
    expect(
      statusesB.map((row) => row['sync_id']).toSet(),
      statusesA.map((row) => row['sync_id']).toSet(),
    );
    expect(book.id, isNot(0));
  });

  test('an edit on one device reaches the other', () async {
    final book = await repoA.createBook({'title': 'Dune'});
    await syncOf(repoA).run();
    await syncOf(repoB).run();

    await repoB.updateBook(book.id, {'notes': 'Borrowed from Jules'});
    final pushed = await syncOf(repoB).run();
    expect(pushed.pushed, isTrue);

    final merged = await syncOf(repoA).run();
    expect(merged.mergedSnapshot, isTrue);
    expect((await repoA.getBook(book.id)).notes, 'Borrowed from Jules');
    expect(merged.merge!.conflicts, isEmpty);
  });

  test('the newest edit wins and the loser is told', () async {
    final book = await repoA.createBook({'title': 'Dune'});
    await syncOf(repoA).run();
    await syncOf(repoB).run();
    // Both sides move after their last successful sync.
    await syncOf(repoA).run();
    await syncOf(repoB).run();

    await repoA.updateBook(book.id, {'subtitle': 'From A'});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await repoB.updateBook(book.id, {'subtitle': 'From B'});

    await syncOf(repoB).run();
    final merged = await syncOf(repoA).run();
    expect((await repoA.getBook(book.id)).subtitle, 'From B');
    expect(merged.merge!.conflicts, isNotEmpty);
  });

  test('a delete travels, and only where it still wins', () async {
    final doomed = await repoA.createBook({'title': 'Doomed'});
    final kept = await repoA.createBook({'title': 'Kept'});
    await syncOf(repoA).run();
    await syncOf(repoB).run();

    await repoA.deleteBook(doomed.id);
    final deleted = await repoA.listBooks();
    expect(deleted.map((book) => book.title), ['Kept']);

    await syncOf(repoA).run();
    await syncOf(repoB).run();
    expect((await repoB.listBooks()).map((book) => book.title), ['Kept']);

    // ... and an edit made after the delete on the other device brings it back.
    await repoB.updateBook(kept.id, {'notes': 'still here'});
    await syncOf(repoB).run();
    await syncOf(repoA).run();
    expect((await repoA.getBook(kept.id)).notes, 'still here');
  });

  test('an edit newer than a delete resurrects the book', () async {
    final book = await repoA.createBook({'title': 'Omar'});
    await syncOf(repoA).run();
    await syncOf(repoB).run();

    await repoA.deleteBook(book.id);
    await syncOf(repoA).run();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final resurrected = await repoB.updateBook(book.id, {'subtitle': 'Still here'});
    expect(resurrected.subtitle, 'Still here');
    await syncOf(repoB).run();

    final merged = await syncOf(repoA).run();
    expect(merged.mergedSnapshot, isTrue);
    expect((await repoA.listBooks()).map((b) => b.title), ['Omar']);
    // The delete is forgotten: the book is back, and A has nothing of its own
    // left to publish (it took B's row, stamp and all).
    final tombstones = await rows(
      repoA.databasePath!,
      'SELECT sync_id FROM sync_tombstones',
    );
    expect(tombstones, isEmpty);
    expect(merged.pushed, isFalse);

    // ... and the resurrection holds on the next round trip.
    await syncOf(repoA).run();
    await syncOf(repoB).run();
    expect((await repoB.listBooks()).map((b) => b.title), ['Omar']);
  });

  test('two devices that typed the same book end up with one', () async {
    await repoA.createBook({
      'title': 'Solo',
      'authors': ['frank herbert'],
      'isbn': '9780000000002',
    });
    await repoB.createBook({
      'title': 'Solo (B)',
      'authors': ['Frank Herbert'],
      'isbn': '9780000000002',
    });

    await syncOf(repoA).run();
    final merged = await syncOf(repoB).run();
    expect((await repoB.listBooks()).length, 1);
    expect((await repoB.listAuthors()).length, 1);
    expect(
      merged.merge!.conflicts.any((note) => note.contains('ISBN')),
      isTrue,
    );

    await syncOf(repoB).run();
    final back = await syncOf(repoA).run();
    expect((await repoA.listBooks()).length, 1);
    expect((await repoA.listAuthors()).length, 1);
    expect(back.mergedSnapshot, isTrue);
  });

  test('the same snapshot merged twice changes nothing', () async {
    await repoA.createBook({'title': 'Dune'});
    await syncOf(repoA).run();
    final snapshot = File(
      '${shared.path}${Platform.pathSeparator}$kSnapshotName',
    );

    final first = await mergeSnapshot(repoB.databasePath!, snapshot);
    expect(first.changes, greaterThan(0));
    final second = await mergeSnapshot(repoB.databasePath!, snapshot);
    expect(second.changes, 0);
  });

  test('a plain export and a torn file are both refused', () async {
    await repoA.createBook({'title': 'Dune'});
    final plain = File('${root.path}/plain.sqlite');
    await repoA.exportTo(plain);
    expect(
      () => readSnapshotMeta(plain),
      throwsA(isA<SyncException>()),
      reason: 'an export has no sync_meta header',
    );

    final torn = File('${root.path}/torn.sqlite');
    await torn.writeAsBytes([1, 2, 3, 4, 5]);
    expect(() => readSnapshotMeta(torn), throwsA(isA<SyncException>()));

    final missing = File('${root.path}/nothing.sqlite');
    expect(() => readSnapshotMeta(missing), throwsA(isA<SyncException>()));
  });

  test('a version 1 library is migrated and backfilled on open', () async {
    await repoA.createBook({'title': 'Old book', 'authors': ['Someone']});
    final path = repoA.databasePath!;
    await repoA.close();

    // Turn the file back into what version 1 looked like: no sync columns, no
    // tombstones table, and the old schema version.
    final db = await openDatabase(path, singleInstance: false);
    try {
      for (final table in kSyncedTables) {
        await db.execute('DROP INDEX IF EXISTS ix_${table}_sync_id');
      }
      for (final table in kSyncedTables) {
        await db.execute('ALTER TABLE $table DROP COLUMN sync_id');
        if (table != 'books') {
          await db.execute('ALTER TABLE $table DROP COLUMN updated_at');
        }
      }
      await db.execute('DROP TABLE IF EXISTS sync_tombstones');
      await db.execute('PRAGMA user_version = 1');
    } finally {
      await db.close();
    }

    await repoA.open('A library');
    final migrated = await rows(
      path,
      'SELECT sync_id, updated_at FROM books',
    );
    expect(migrated.single['sync_id'], isNotNull);
    expect((migrated.single['sync_id'] as String).length, 32);
    expect(migrated.single['updated_at'], isNotNull);
    final statuses = await rows(path, 'SELECT sync_id FROM statuses');
    expect(statuses.every((row) => row['sync_id'] != null), isTrue);
    final version = await rows(path, 'PRAGMA user_version');
    expect('${version.single.values.first}', '$kLibrarySchemaVersion');
  });

  test('timestamps are compared as instants, not as text', () {
    expect(stampMicros('2026-01-02 03:04:05.000001'), greaterThan(0));
    expect(
      stampMicros('2026-01-02T03:04:05.000001'),
      stampMicros('2026-01-02 03:04:05.000001'),
    );
    expect(
      stampMicros('2026-01-02T05:04:05.000001+02:00'),
      stampMicros('2026-01-02 03:04:05.000001'),
    );
    expect(stampMicros('2026-01-02T03:04:05Z'), stampMicros('2026-01-02 03:04:05'));
    expect(stampMicros(null), 0);
    expect(stampMicros('nonsense'), 0);
  });
}
