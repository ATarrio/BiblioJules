/// A whole BiblioJules library kept in a SQLite file on the device.
///
/// This is the second implementation of [LibraryRepo] (the first being
/// [ApiClient]). It ports ``app/services/library.py``: the same filters, the
/// same sort orders, the same rules about what happens when a book is lent or
/// a shelf is deleted. The SQL is written to be legible *next to* the Python it
/// mirrors, so the two can be diffed by eye.
///
/// Two deliberate choices stand out:
///
/// * **Reads return the API's JSON maps** (built here, parsed by the very same
///   ``Book.fromJson`` the HTTP client uses). The screens therefore cannot tell
///   the modes apart, and a serialisation bug shows up in both.
/// * **``NULLS LAST`` is emulated** with ``ORDER BY (col IS NULL), col``. SQLite
///   only learned ``NULLS LAST`` in 3.30, and Android 10 ships 3.28 — a phone
///   must not sort differently from a laptop.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../core/api_exception.dart';
import '../core/book_fields.dart';
import '../core/l10n.dart';
import '../core/library_repo.dart';
import '../core/models/models.dart';
import '../core/util.dart';
import 'converters.dart';
import 'library_files.dart';
import 'lookup.dart';
import 'schema.dart';
import 'sync_ids.dart';

class LocalRepo implements LibraryRepo {
  LocalRepo({Future<Directory> Function()? documentsDirectory})
    : _documentsDirectory =
          documentsDirectory ?? getApplicationDocumentsDirectory;

  /// Where libraries are kept. Injected so tests (which have no platform
  /// channel for ``path_provider``) can point at a temporary directory.
  final Future<Directory> Function() _documentsDirectory;

  /// The open database, or ``null`` when no library is in use.
  Database? _db;

  /// The name the user gave the open library.
  String? _libraryName;

  /// The string catalogue, so the messages raised here are translated like the
  /// ones the server sends. Set by the app when the language changes.
  L10n? _l10n;

  final OnlineLookup _lookup = OnlineLookup();

  /// Serialise read-modify-write cycles on the reading JSON files, so two
  /// quick taps cannot lose an entry. File writes are atomic (temp + rename).
  Future<void> _readingQueue = Future<void>.value();

  // ------------------------------------------------------------------------- //
  // Lifecycle
  // ------------------------------------------------------------------------- //

  /// True once a library has been opened.
  bool get isOpen => _db != null;

  /// The open library's file, or ``null``. The shared-library sync needs the
  /// path: it opens a second connection to the same file to merge a snapshot.
  String? get databasePath => _db?.path;

  /// The open library's name, or ``null``.
  String? get libraryName => _libraryName;

  /// Use the current language's catalogue for our own error messages.
  void useMessages(L10n l10n) => _l10n = l10n;

  /// Open (creating and seeding it the first time) the library called [name].
  ///
  /// Switching libraries closes whatever was open, so there is never more than
  /// one database handle.
  Future<void> open(String name) async {
    await close();
    final folder = await _librariesFolder();
    final path =
        '${folder.path}${Platform.pathSeparator}${libraryFileName(name)}';
    final file = File(path);
    if (file.existsSync()) {
      // A database that arrived by hand — a server's ``data/library.db`` copied
      // into place, say — carries no schema version, and sqflite reads that as
      // "brand new" and tries to create tables that are already there. The
      // import path stamps its files; this covers the ones that skipped it.
      await _stampSchemaVersion(file);
    }
    final database = await openDatabase(
      path,
      version: kLibrarySchemaVersion,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        for (final statement in kLibrarySchemaStatements) {
          await db.execute(statement);
        }
        await _seedDefaults(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Version 1 → 2: the shared-library columns (sync ids, change stamps
        // and the tombstones deletions travel as). Mirrors the server's
        // ``ensure_sync_schema``; see schema.dart for the statements.
        if (oldVersion < 2) {
          await _upgradeToSyncSchema(db);
        }
        // Version 2 → 3: reading objectives move from a side JSON file into a
        // table, so the single-file export carries them.
        if (oldVersion < 3) {
          for (final statement in kGoalsMigrationStatements) {
            await db.execute(statement);
          }
        }
      },
    );
    _db = database;
    _libraryName = name;
    // Objectives used to be a side JSON file; move them into the table once so
    // the single-file export carries them.
    await _migrateLegacyGoals(database);
  }

  /// Add the sync columns to a library that predates sharing, and fill them in.
  ///
  /// SQLite refuses ``ADD COLUMN ... NOT NULL``, so the columns arrive empty and
  /// every existing row is given an id and a change stamp immediately after.
  /// Doing it here (rather than lazily on first read) keeps the rest of the
  /// store free of null checks, exactly as the server's backfill does.
  Future<void> _upgradeToSyncSchema(DatabaseExecutor db) async {
    for (final statement in kSyncMigrationStatements) {
      try {
        await db.execute(statement);
      } on DatabaseException catch (error) {
        // A file that got half-way through an earlier attempt is fine: adding
        // an existing column is the one failure worth ignoring.
        if (!'$error'.toLowerCase().contains('duplicate column')) rethrow;
      }
    }
    await _backfillSyncIds(db);
  }

  Future<void> _backfillSyncIds(DatabaseExecutor db) async {
    for (final table in kSyncedTables) {
      final rows = await db.query(
        table,
        columns: const <String>['id'],
        where: 'sync_id IS NULL',
      );
      for (final row in rows) {
        await db.update(
          table,
          <String, Object?>{'sync_id': newSyncId()},
          where: 'id = ?',
          whereArgs: <Object?>[row['id']],
        );
      }
    }
    final now = nowStamp();
    // ``books`` has had ``updated_at`` since the first release; the rest are
    // seeded from ``created_at`` where the table has one, so an old row does
    // not look as though it changed the moment the app was updated.
    for (final table in const <String>['authors', 'publishers']) {
      await db.rawUpdate(
        'UPDATE $table SET updated_at = ? WHERE updated_at IS NULL',
        <Object?>[now],
      );
    }
    for (final table in const <String>['locations', 'statuses', 'loans']) {
      await db.rawUpdate(
        'UPDATE $table SET updated_at = COALESCE(created_at, ?)'
        ' WHERE updated_at IS NULL',
        <Object?>[now],
      );
    }
  }

  /// Close the open library, if any. Safe to call when nothing is open.
  Future<void> close() async {
    final db = _db;
    _db = null;
    _libraryName = null;
    _lookup.close();
    if (db != null) await db.close();
  }

  /// Called when the provider that owns this repo is torn down.
  Future<void> dispose() => close();

  Future<Directory> _librariesFolder() async {
    final base = await _documentsDirectory();
    final folder = Directory(
      '${base.path}${Platform.pathSeparator}$kLibrariesFolder',
    );
    if (!folder.existsSync()) await folder.create(recursive: true);
    return folder;
  }

  /// Where the device-wide reading goals and want-to-read list live.
  ///
  /// They are deliberately not next to one library: like the server's
  /// ``data/goals.json`` they belong to the device, and renaming a library
  /// must not make them disappear.
  Future<Directory> _readingFolder() async {
    final base = await _documentsDirectory();
    final folder = Directory('${base.path}${Platform.pathSeparator}reading');
    if (!folder.existsSync()) await folder.create(recursive: true);
    return folder;
  }

  Future<File> _readingFile(String name) async {
    final folder = await _readingFolder();
    return File('${folder.path}${Platform.pathSeparator}$name');
  }

  Future<Directory> _coversFolder() async {
    final base = await _documentsDirectory();
    final folder = Directory('${base.path}${Platform.pathSeparator}covers');
    if (!folder.existsSync()) await folder.create(recursive: true);
    return folder;
  }

  /// Serialise one read-modify-write of [action] behind earlier ones.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _readingQueue.then((_) => action());
    _readingQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<Object?> _readJsonFile(File file, Object? fallback) async {
    try {
      return jsonDecode(await file.readAsString());
    } on FileSystemException {
      return fallback;
    } on FormatException {
      return fallback;
    }
  }

  Future<void> _writeJsonFile(File file, Object? data) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsString(jsonEncode(data), flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  /// Image extension from the bytes themselves, mirroring ``covers.py``.
  String? _sniffImage(List<int> bytes) {
    bool starts(List<int> prefix) {
      if (bytes.length < prefix.length) return false;
      for (var index = 0; index < prefix.length; index++) {
        if (bytes[index] != prefix[index]) return false;
      }
      return true;
    }

    if (starts(const [0xFF, 0xD8, 0xFF])) return '.jpg';
    if (starts(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return '.png';
    }
    if (starts(const [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
        starts(const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) {
      return '.gif';
    }
    if (bytes.length >= 12 &&
        starts(const [0x52, 0x49, 0x46, 0x46]) &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }
    return null;
  }

  /// The path of the library file called [name] (whether or not it exists).
  Future<File> libraryFile(String name) async {
    final folder = await _librariesFolder();
    return File(
      '${folder.path}${Platform.pathSeparator}${libraryFileName(name)}',
    );
  }

  /// Give the open library a new name, moving its file when the slug changes.
  ///
  /// Renaming onto a name another file already holds is refused rather than
  /// silently opening that other library instead.
  Future<void> renameTo(String newName) async {
    final label = newName.trim();
    if (label.isEmpty || label == _libraryName) return;
    final current = _libraryName;
    if (current == null) {
      await open(label);
      return;
    }
    if (librarySlug(current) == librarySlug(label)) {
      // Same file, nicer label.
      _libraryName = label;
      return;
    }

    final source = await libraryFile(current);
    final target = await libraryFile(label);
    if (target.existsSync()) {
      throw ApiValidationException(
        _tf('A library named “%s” already exists on this device.', <Object?>[
          label,
        ]),
        statusCode: 400,
      );
    }

    await close();
    if (source.existsSync()) {
      // SQLite may leave WAL sidecars behind; they travel with the file.
      for (final suffix in const <String>['', '-wal', '-shm']) {
        final from = File('${source.path}$suffix');
        if (from.existsSync()) await from.rename('${target.path}$suffix');
      }
    }
    await open(label);
  }

  // ------------------------------------------------------------------------- //
  // Moving a library in and out
  // ------------------------------------------------------------------------- //

  /// Write a self-contained snapshot of the open library to [target].
  ///
  /// A plain file copy would not do: the newest writes are still in the
  /// write-ahead log. So the log is folded back into the main file and then
  /// ``VACUUM INTO`` writes a compact copy — one file, nothing to keep beside
  /// it. Old SQLite builds (Android before 9) have no ``VACUUM INTO``; there the
  /// checkpoint alone is enough for a byte copy, so that is the fallback.
  Future<void> exportTo(File target) async {
    final db = _requireDb();
    if (target.existsSync()) await target.delete();
    if (!target.parent.existsSync()) {
      await target.parent.create(recursive: true);
    }

    // Any pending WAL frames belong in the file we are about to copy. This is a
    // query, not an ``execute``: the pragma answers with a row, and Android's
    // sqflite refuses row-returning statements through ``execute`` — while the
    // FFI build the tests run on accepts them, which is how this slipped
    // through once. Every pragma here goes through ``rawQuery`` for that reason.
    await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    try {
      final path = target.path.replaceAll("'", "''");
      await db.execute("VACUUM INTO '$path'");
    } on DatabaseException {
      // VACUUM INTO needs SQLite 3.27; the checkpoint above already made the
      // main file complete, so copying it is safe.
      final source = File(db.path);
      await source.copy(target.path);
    }
  }

  /// Replace the open library with the contents of [source].
  ///
  /// [source] is validated first and the current file is only swapped out once
  /// the new one is in place, so a bad file (or a full disk) leaves the library
  /// exactly as it was.
  Future<void> importFrom(File source) async {
    final name = _libraryName;
    if (name == null) {
      throw ApiException('No local library is open.');
    }
    await validateLibraryFile(source);

    final target = await libraryFile(name);
    final previous = File('${target.path}.previous');
    if (previous.existsSync()) await previous.delete();

    await close();
    final hadFile = target.existsSync();
    if (hadFile) await target.rename(previous.path);
    try {
      await source.copy(target.path);
      await _stampSchemaVersion(target);
    } on Object {
      // Put the old library back rather than leave the user with nothing.
      if (target.existsSync()) await target.delete();
      if (hadFile && previous.existsSync()) await previous.rename(target.path);
      rethrow;
    }
    if (previous.existsSync()) await previous.delete();
    await open(name);
  }

  /// Throw unless [file] looks like a BiblioJules library we can read.
  ///
  /// Written to be forgiving about what a library may *also* contain: a server's
  /// ``data/library.db`` carries ``users`` and ``tokens`` tables (and has never
  /// been stamped with a schema version), and both must import cleanly. What it
  /// will not accept is a file missing something the app needs, or one that is
  /// simply not an SQLite database.
  Future<void> validateLibraryFile(File file) async {
    if (!file.existsSync() || file.lengthSync() == 0) {
      throw ApiValidationException(
        _t('The chosen file is empty.'),
        statusCode: 400,
      );
    }

    final Database db;
    try {
      // Read-only, and with no version: nothing here should touch the file.
      db = await openDatabase(file.path, readOnly: true);
    } on DatabaseException {
      throw ApiValidationException(
        _t('The chosen file is not a BiblioJules library.'),
        statusCode: 400,
      );
    }

    try {
      // SQLite opens a file lazily and only complains on the first read, so the
      // "is this even a database?" question is answered in here as well.
      await _checkLibraryShape(db);
    } on DatabaseException {
      throw ApiValidationException(
        _t('The chosen file is not a BiblioJules library.'),
        statusCode: 400,
      );
    } finally {
      await db.close();
    }
  }

  /// The shape checks behind [validateLibraryFile], kept apart so every failure
  /// mode reports the same thing.
  Future<void> _checkLibraryShape(DatabaseExecutor db) async {
    final version =
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')) ?? 0;
    if (version > kLibrarySchemaVersion) {
      // Newer than we know how to read: refuse rather than half-read it.
      throw ApiValidationException(
        _t('This library needs a newer version of the app.'),
        statusCode: 400,
      );
    }

    final tables = <String>{
      for (final row in await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ))
        '${row['name']}'.toLowerCase(),
    };
    final missing = kRequiredTables.where((t) => !tables.contains(t)).toList();
    if (missing.isNotEmpty) {
      throw ApiValidationException(
        _t('The chosen file is not a BiblioJules library.'),
        statusCode: 400,
      );
    }

    // A right-but-incomplete set of columns would still fail later, which is
    // exactly why it is checked here: the message names the file, not a column.
    final columns = await db.rawQuery('PRAGMA table_info(books)');
    final names = <String>{for (final row in columns) '${row['name']}'};
    if (!names.contains('title')) {
      throw ApiValidationException(
        _t('The chosen file is not a BiblioJules library.'),
        statusCode: 400,
      );
    }
  }

  /// Mark [file] as being at the current schema version, if it is not already.
  ///
  /// ``sqflite`` treats ``user_version = 0`` as "brand new" and would try to
  /// create the tables it finds already there, so a database that arrived from
  /// a server has to be stamped before it is opened. A file that already
  /// carries the version is left untouched.
  Future<void> _stampSchemaVersion(File file) async {
    final db = await openDatabase(
      file.path,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
    try {
      final version =
          Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')) ?? 0;
      if (version != 0) return;
      // ``user_version = 0`` means either a brand-new file or a database that
      // arrived without a stamp. Look at the actual tables: a v1 library still
      // needs the 1 -> 2 upgrade (sync columns), only a v2 one may be stamped
      // as current. Stamping a v1 file as v2 would silently skip that upgrade.
      final tables = <String>{
        for (final row in await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        ))
          '${row['name']}'.toLowerCase(),
      };
      if (!tables.contains('books')) return; // empty file: let onCreate run
      final columns = await db.rawQuery('PRAGMA table_info(books)');
      final hasSync = columns.any((row) => row['name'] == 'sync_id');
      final hasGoals = tables.contains('reading_goals');
      final stamped = hasGoals ? kLibrarySchemaVersion : (hasSync ? 2 : 1);
      await db.execute(
        'PRAGMA user_version = $stamped',
      );
    } finally {
      await db.close();
    }
  }

  Database _requireDb() {
    final db = _db;
    if (db == null) {
      throw ApiException('No local library is open.');
    }
    return db;
  }

  Future<void> _seedDefaults(DatabaseExecutor db) async {
    final existing =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM statuses'),
        ) ??
        0;
    if (existing > 0) return;
    final now = nowStamp();
    for (final spec in kDefaultStatuses) {
      await db.insert('statuses', <String, Object?>{
        'name': spec['name'],
        'slug': spec['slug'],
        'color': spec['color'],
        'icon': spec['icon'],
        'description': null,
        'sort_order': spec['sort_order'],
        'is_system': 1,
        'is_default': spec['is_default'] == true ? 1 : 0,
        'created_at': now,
        'sync_id': newSyncId(),
        'updated_at': now,
      });
    }
  }

  // ------------------------------------------------------------------------- //
  // Messages
  // ------------------------------------------------------------------------- //
  String _t(String source) => _l10n?.tr(source) ?? source;

  String _tf(String source, List<Object?> args) =>
      _l10n?.tf(source, args) ?? source;

  // ------------------------------------------------------------------------- //
  // Reading books
  // ------------------------------------------------------------------------- //
  @override
  Future<List<Book>> listBooks({
    String? search,
    int? statusId,
    int? locationId,
    int? authorId,
    int? publisherId,
    String? loaned,
    String? saga,
    String? readStatus,
    String sort = 'recent',
    String? direction,
  }) async {
    final items = await _listBooksJson(
      search: search,
      statusId: statusId,
      locationId: locationId,
      authorId: authorId,
      publisherId: publisherId,
      loaned: loaned,
      saga: saga,
      readStatus: readStatus,
      sort: sort,
      direction: direction,
    );
    return items.map(Book.fromJson).toList();
  }

  /// The query behind [listBooks], handed back as the API's maps so the
  /// dashboard can build its six "recently added" cards from the same code.
  Future<List<Map<String, dynamic>>> _listBooksJson({
    String? search,
    int? statusId,
    int? locationId,
    int? authorId,
    int? publisherId,
    String? loaned,
    String? saga,
    String? readStatus,
    String sort = 'recent',
    String? direction,
  }) async {
    final db = _requireDb();
    final where = <String>[];
    final args = <Object?>[];

    // ``search`` spans the book, its authors and its publisher. The server gets
    // there with outer joins + DISTINCT; EXISTS says the same thing without
    // needing the dedupe, and keeps the ORDER BY expressions simple.
    if (search != null && search.trim().isNotEmpty) {
      final term = '%${search.trim().toLowerCase()}%';
      where.add(
        '(lower(b.title) LIKE ?'
        ' OR lower(b.subtitle) LIKE ?'
        ' OR lower(b.isbn) LIKE ?'
        ' OR EXISTS (SELECT 1 FROM book_authors ba JOIN authors a'
        '     ON a.id = ba.author_id'
        '     WHERE ba.book_id = b.id AND lower(a.name) LIKE ?)'
        ' OR EXISTS (SELECT 1 FROM publishers p'
        '     WHERE p.id = b.publisher_id AND lower(p.name) LIKE ?))',
      );
      args.addAll(<Object?>[term, term, term, term, term]);
    }
    if (statusId != null) {
      where.add('b.status_id = ?');
      args.add(statusId);
    }
    if (publisherId != null) {
      where.add('b.publisher_id = ?');
      args.add(publisherId);
    }
    if (authorId != null) {
      where.add(
        'EXISTS (SELECT 1 FROM book_authors ba'
        '   WHERE ba.book_id = b.id AND ba.author_id = ?)',
      );
      args.add(authorId);
    }
    if (locationId != null) {
      // Filtering by a shelf also matches everything stored under it.
      final locations = await _locationRows(db);
      if (locations.containsKey(locationId)) {
        final ids = _descendantIds(locations, locationId);
        final marks = List.filled(ids.length, '?').join(', ');
        where.add('b.location_id IN ($marks)');
        args.addAll(ids);
      }
    }
    if (saga != null && saga.trim().isNotEmpty) {
      where.add('lower(b.saga) = ?');
      args.add(saga.trim().toLowerCase());
    }
    if (readStatus != null && kReadStatuses.containsKey(readStatus.trim())) {
      where.add('b.read_status = ?');
      args.add(readStatus.trim());
    }
    if (loaned == 'loaned') {
      where.add(
        'EXISTS (SELECT 1 FROM loans l'
        '   WHERE l.book_id = b.id AND l.returned_at IS NULL)',
      );
    } else if (loaned == 'available') {
      where.add(
        'NOT EXISTS (SELECT 1 FROM loans l'
        '   WHERE l.book_id = b.id AND l.returned_at IS NULL)',
      );
    }

    final clause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final explicitDirection = direction == 'desc'
        ? true
        : (direction == 'asc' ? false : null);
    // Each sort has its own natural direction, which an explicit one overrides.
    final descending = explicitDirection ?? false;
    final newestFirst = explicitDirection ?? true;

    late String orderBy;
    switch (sort) {
      case 'title':
        orderBy = 'lower(b.title) ${descending ? 'DESC' : 'ASC'}';
      case 'year':
        orderBy =
            '(b.published_year IS NULL),'
            ' b.published_year ${newestFirst ? 'DESC' : 'ASC'}';
      case 'saga':
        orderBy =
            '(lower(b.saga) IS NULL), lower(b.saga) ${descending ? 'DESC' : 'ASC'},'
            ' b.saga_number ASC, lower(b.title) ASC';
      case 'author':
        // Author names live across a many-to-many join, so the ordering happens
        // below on the loaded rows (cheap for a personal library).
        orderBy = 'b.id ASC';
      default: // recent
        orderBy =
            'b.created_at ${newestFirst ? 'DESC' : 'ASC'},'
            ' b.id ${newestFirst ? 'DESC' : 'ASC'}';
    }

    final rows = await db.rawQuery(
      'SELECT b.* FROM books b $clause ORDER BY $orderBy',
      args,
    );
    final items = await _booksJson(db, rows);

    if (sort == 'author') {
      // Same key as the server: the alphabetically first author name, then the
      // title — both case-folded.
      String keyOf(Map<String, dynamic> item) {
        final names =
            (item['authors'] as List)
                .map((name) => '$name'.toLowerCase())
                .toList()
              ..sort();
        final first = names.isEmpty ? '' : names.first;
        return '$first\u0000${'${item['title']}'.toLowerCase()}';
      }

      final keyed = items.map((item) => (keyOf(item), item)).toList()
        ..sort((a, b) => a.$1.compareTo(b.$1));
      if (explicitDirection == true) {
        items.setAll(0, keyed.reversed.map((entry) => entry.$2).toList());
      } else {
        items.setAll(0, keyed.map((entry) => entry.$2).toList());
      }
    }
    return items;
  }

  @override
  Future<Book> getBook(int id) async {
    final db = _requireDb();
    final row = await _bookRow(db, id);
    if (row == null) throw ApiNotFoundException(_t('Book not found'));
    return Book.fromJson((await _booksJson(db, [row])).single);
  }

  @override
  Future<Book?> findByIsbn(String isbn) async {
    final db = _requireDb();
    final normalized = normalizeIsbn(isbn);
    if (normalized.isEmpty) return null;
    final rows = await db.query(
      'books',
      where: 'isbn = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Book.fromJson((await _booksJson(db, rows)).single);
  }

  @override
  Future<List<Loan>> bookLoans(int bookId) async {
    final db = _requireDb();
    if (await _bookRow(db, bookId) == null) {
      throw ApiNotFoundException(_t('Book not found'));
    }
    final rows = await db.query(
      'loans',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'lent_at DESC, id DESC',
    );
    return rows.map((row) => Loan.fromJson(loanToJson(row))).toList();
  }

  Future<Map<String, Object?>?> _bookRow(DatabaseExecutor db, int id) async {
    final rows = await db.query(
      'books',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Rows -> the API's book maps.
  ///
  /// Reference tables are small in a personal library (and active loans are by
  /// definition few), so they are read whole and grouped here. That keeps every
  /// query free of ``IN (…)`` lists, which SQLite limits to 999 placeholders on
  /// the very devices this app supports.
  Future<List<Map<String, dynamic>>> _booksJson(
    DatabaseExecutor db,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return const <Map<String, dynamic>>[];

    final statuses = await _statusRows(db);
    final locations = await _locationRows(db);
    final publishers = <int, String>{
      for (final row in await db.query('publishers'))
        row['id']! as int: row['name']! as String,
    };

    final authors = <int, List<String>>{};
    for (final row in await db.rawQuery(
      'SELECT ba.book_id AS book_id, a.name AS name'
      ' FROM book_authors ba JOIN authors a ON a.id = ba.author_id'
      ' ORDER BY a.name',
    )) {
      (authors[row['book_id']! as int] ??= <String>[]).add(
        row['name']! as String,
      );
    }

    final loans = <int, Map<String, Object?>>{};
    for (final row in await db.rawQuery(
      'SELECT * FROM loans WHERE returned_at IS NULL ORDER BY lent_at DESC, id DESC',
    )) {
      // First one wins; the query is newest-first, which is how the server's
      // ``Book.active_loan`` picks as well.
      loans.putIfAbsent(row['book_id']! as int, () => row);
    }

    return <Map<String, dynamic>>[
      for (final row in rows)
        _bookJson(row, authors, publishers, statuses, locations, loans),
    ];
  }

  Map<String, dynamic> _bookJson(
    Map<String, Object?> row,
    Map<int, List<String>> authors,
    Map<int, String> publishers,
    Map<int, Map<String, Object?>> statuses,
    Map<int, Map<String, Object?>> locations,
    Map<int, Map<String, Object?>> loans,
  ) {
    final id = row['id']! as int;
    final locationId = row['location_id'] as int?;
    final statusId = row['status_id'] as int?;
    final locationRow = locationId == null ? null : locations[locationId];
    final statusRow = statusId == null ? null : statuses[statusId];
    final loanRow = loans[id];

    return bookToJson(
      row,
      authors: authors[id] ?? const <String>[],
      publisher: publishers[row['publisher_id'] as int?],
      location: locationRow == null
          ? null
          : locationToJson(
              locationRow,
              fullPath: _fullPath(locations, locationId!),
            ),
      status: statusRow == null ? null : statusToJson(statusRow),
      activeLoan: loanRow == null ? null : loanToJson(loanRow),
    );
  }

  // ------------------------------------------------------------------------- //
  // Writing books
  // ------------------------------------------------------------------------- //
  @override
  Future<Book> createBook(Map<String, dynamic> payload) async {
    final db = _requireDb();
    var data = payload;
    final id = await db.transaction<int>((txn) async {
      final now = nowStamp();
      final values = <String, Object?>{
        'title': 'Untitled',
        'created_at': now,
        'updated_at': now,
        'sync_id': newSyncId(),
      };
      if (_isFalsy(data['status_id'])) {
        final fallback = await _defaultStatusId(txn);
        if (fallback != null) {
          data = <String, dynamic>{...data, 'status_id': fallback};
        }
      }
      values.addAll(await _applyFields(txn, data, currentPublishedDate: null));
      final bookId = await txn.insert('books', values);
      await _applyRelations(txn, bookId, data);
      return bookId;
    });
    return getBook(id);
  }

  @override
  Future<Book> updateBook(int id, Map<String, dynamic> payload) async {
    final db = _requireDb();
    final existing = await _bookRow(db, id);
    if (existing == null) throw ApiNotFoundException(_t('Book not found'));
    final previousStatus = existing['read_status'] as String?;
    await db.transaction((txn) async {
      final values = await _applyFields(
        txn,
        payload,
        currentPublishedDate: existing['published_date'] as String?,
      );
      values['updated_at'] = nowStamp();
      await txn.update('books', values, where: 'id = ?', whereArgs: [id]);
      await _applyRelations(txn, id, payload);
      // A book newly marked read counts toward the objective for this year
      // (and any "any year" objective). Progress is per objective, never the
      // all-time dashboard count, which is derived from the library on each
      // read.
      final newStatus = values.containsKey('read_status')
          ? values['read_status'] as String?
          : previousStatus;
      if (newStatus == 'read' && previousStatus != 'read') {
        final pages = values.containsKey('page_count')
            ? (values['page_count'] as int? ?? 0)
            : ((existing['page_count'] as int?) ?? 0);
        await _recordRead(txn, pages);
      }
    });
    // Editing a book's authors or publisher can strand the previous ones.
    await _pruneOrphans(db);
    return getBook(id);
  }

  @override
  Future<bool> deleteBook(int id) async {
    final db = _requireDb();
    if (await _bookRow(db, id) == null) {
      throw ApiNotFoundException(_t('Book not found'));
    }
    // Loans and author links go with it: both are ON DELETE CASCADE, and
    // foreign keys are switched on when the file is opened. The tombstone
    // travels so the other devices delete their copy instead of re-adding it.
    await _recordTombstones(db, 'books', <String?>[
      (await _bookRow(db, id))?['sync_id'] as String?,
    ]);
    await db.delete('books', where: 'id = ?', whereArgs: [id]);
    await _pruneOrphans(db);
    return true;
  }

  /// Port of ``library.apply_book_data``: only the fields the caller actually
  /// sent are touched, which is how a client clears a value (send ``null``).
  Future<Map<String, Object?>> _applyFields(
    DatabaseExecutor db,
    Map<String, dynamic> data, {
    required String? currentPublishedDate,
  }) async {
    final values = <String, Object?>{};
    bool has(String key) => data.containsKey(key);

    if (has('isbn')) {
      final isbn = normalizeIsbn('${data['isbn'] ?? ''}');
      values['isbn'] = isbn.isEmpty ? null : isbn;
    }
    if (has('title')) {
      final title = '${data['title'] ?? ''}'.trim();
      values['title'] = title.isEmpty ? 'Untitled' : title;
    }
    for (final field in const <String>[
      'subtitle',
      'description',
      'language',
      'cover_url',
      'notes',
      'source',
    ]) {
      if (has(field)) {
        final value = data[field];
        values[field] = value is String ? value.trim() : value;
      }
    }

    // ``published_date`` is the single field the user edits; ``published_year``
    // is a cached projection of it, kept so the Year sort stays a plain column.
    var publishedDate = currentPublishedDate;
    if (has('published_date')) {
      final value = data['published_date'];
      publishedDate = (value is String && value.trim().isNotEmpty)
          ? value.trim()
          : null;
      values['published_date'] = publishedDate;
    }
    if (has('published_year')) {
      final year = _toInt(data['published_year']);
      if (_isFalsy(publishedDate) && !_isFalsy(year)) {
        // A year-only input (an online lookup, say) still fills the single date
        // field so it can be seen and edited.
        publishedDate = '$year';
        values['published_date'] = publishedDate;
      }
    }
    if (has('published_date') || has('published_year')) {
      var year = extractYear(publishedDate);
      if (year == null && has('published_year')) {
        // The date has no readable year ("MMV"): keep the supplied one.
        year = _toInt(data['published_year']);
      }
      values['published_year'] = year;
    }

    if (has('page_count')) values['page_count'] = _toInt(data['page_count']);
    if (has('cover_type')) {
      final value = '${data['cover_type'] ?? ''}'.trim();
      values['cover_type'] = kCoverTypes.containsKey(value) ? value : null;
    }
    if (has('read_status')) {
      final value = '${data['read_status'] ?? ''}'.trim();
      values['read_status'] = kReadStatuses.containsKey(value) ? value : null;
    }
    if (has('score')) values['score'] = _toScore(data['score']);
    if (has('saga')) {
      final value = '${data['saga'] ?? ''}'.trim();
      values['saga'] = value.isEmpty ? null : value;
    }
    if (has('saga_number')) values['saga_number'] = _toInt(data['saga_number']);
    if (has('location_id')) values['location_id'] = _toId(data['location_id']);
    if (has('status_id')) values['status_id'] = _toId(data['status_id']);
    return values;
  }

  /// Authors and publisher are rows of their own, so they are written after the
  /// book exists rather than as columns on it.
  Future<void> _applyRelations(
    DatabaseExecutor db,
    int bookId,
    Map<String, dynamic> data,
  ) async {
    if (data.containsKey('publisher')) {
      final name = '${data['publisher'] ?? ''}'.trim();
      final publisherId = name.isEmpty
          ? null
          : await _getOrCreatePublisher(db, name);
      await db.update(
        'books',
        <String, Object?>{'publisher_id': publisherId},
        where: 'id = ?',
        whereArgs: <Object?>[bookId],
      );
    }
    if (data.containsKey('authors')) {
      // Assigning replaces the whole list, exactly like the relationship does.
      await db.delete(
        'book_authors',
        where: 'book_id = ?',
        whereArgs: <Object?>[bookId],
      );
      final seen = <String>{};
      for (final name in _splitNames(data['authors'])) {
        if (!seen.add(name.toLowerCase())) continue;
        final authorId = await _getOrCreateAuthor(db, name);
        await db.insert('book_authors', <String, Object?>{
          'book_id': bookId,
          'author_id': authorId,
        });
      }
    }
  }

  Future<int> _getOrCreateAuthor(DatabaseExecutor db, String name) async {
    final existing = await db.query(
      'authors',
      where: 'lower(name) = ?',
      whereArgs: <Object?>[name.toLowerCase()],
      limit: 1,
    );
    if (existing.isNotEmpty) return existing.first['id']! as int;
    return db.insert('authors', <String, Object?>{
      'name': name,
      'sync_id': newSyncId(),
      'updated_at': nowStamp(),
    });
  }

  Future<int> _getOrCreatePublisher(DatabaseExecutor db, String name) async {
    final existing = await db.query(
      'publishers',
      where: 'lower(name) = ?',
      whereArgs: <Object?>[name.toLowerCase()],
      limit: 1,
    );
    if (existing.isNotEmpty) return existing.first['id']! as int;
    return db.insert('publishers', <String, Object?>{
      'name': name,
      'sync_id': newSyncId(),
      'updated_at': nowStamp(),
    });
  }

  /// Note that a row was deleted, so the deletion can travel.
  ///
  /// A merge only sees two databases: a row missing from one could have been
  /// deleted there or simply never created. The note (never shown to the user)
  /// is what tells the two apart. Mirrors ``app/services/tombstones.py``.
  Future<void> _recordTombstones(
    DatabaseExecutor db,
    String table,
    Iterable<String?> syncIds,
  ) async {
    final now = nowStamp();
    for (final syncId in syncIds) {
      if (syncId == null || syncId.isEmpty) continue;
      await db.insert('sync_tombstones', <String, Object?>{
        'table_name': table,
        'sync_id': syncId,
        'deleted_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Delete authors and publishers no longer linked to any book, so the filter
  /// dropdowns (and the dashboard's author count) do not fill up with ghosts.
  Future<void> _pruneOrphans(DatabaseExecutor db) async {
    await db.rawDelete(
      'DELETE FROM authors WHERE id NOT IN (SELECT author_id FROM book_authors)',
    );
    await db.rawDelete(
      'DELETE FROM publishers'
      ' WHERE id NOT IN (SELECT publisher_id FROM books WHERE publisher_id IS NOT NULL)',
    );
  }

  // ------------------------------------------------------------------------- //
  // Loans
  // ------------------------------------------------------------------------- //
  @override
  Future<Loan> lendBook(
    int bookId, {
    required String borrowerName,
    String? borrowerContact,
    String? lentAt,
    String? dueAt,
    String? notes,
    bool markStatus = true,
  }) async {
    final db = _requireDb();
    if (await _bookRow(db, bookId) == null) {
      throw ApiNotFoundException(_t('Book not found'));
    }
    final id = await db.transaction<int>((txn) async {
      final contact = (borrowerContact ?? '').trim();
      final note = (notes ?? '').trim();
      final loanId = await txn.insert('loans', <String, Object?>{
        'book_id': bookId,
        'borrower_name': borrowerName.trim(),
        'borrower_contact': contact.isEmpty ? null : contact,
        'lent_at': (lentAt == null || lentAt.trim().isEmpty)
            ? todayDate()
            : lentAt.trim(),
        'due_at': (dueAt == null || dueAt.trim().isEmpty) ? null : dueAt.trim(),
        'returned_at': null,
        'notes': note.isEmpty ? null : note,
        'created_at': nowStamp(),
        'sync_id': newSyncId(),
        'updated_at': nowStamp(),
      });
      if (markStatus) {
        final lent = await _statusBySlug(txn, 'lent');
        if (lent != null) {
          await txn.update(
            'books',
            <String, Object?>{'status_id': lent, 'updated_at': nowStamp()},
            where: 'id = ?',
            whereArgs: <Object?>[bookId],
          );
        }
      }
      return loanId;
    });
    final row = await db.query(
      'loans',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    return Loan.fromJson(loanToJson(row.first));
  }

  @override
  Future<void> returnBook(
    int bookId, {
    String? returnedAt,
    bool restoreStatus = true,
  }) async {
    final db = _requireDb();
    if (await _bookRow(db, bookId) == null) {
      throw ApiNotFoundException(_t('Book not found'));
    }
    await db.transaction((txn) async {
      // The active loan is the newest one still out.
      final active = await txn.query(
        'loans',
        where: 'book_id = ? AND returned_at IS NULL',
        whereArgs: <Object?>[bookId],
        orderBy: 'lent_at DESC, id DESC',
        limit: 1,
      );
      final stamp = (returnedAt == null || returnedAt.trim().isEmpty)
          ? todayDate()
          : returnedAt.trim();
      if (active.isNotEmpty) {
        await txn.update(
          'loans',
          <String, Object?>{'returned_at': stamp, 'updated_at': nowStamp()},
          where: 'id = ?',
          whereArgs: <Object?>[active.first['id']],
        );
      }
      if (restoreStatus) {
        final available = await _statusBySlug(txn, 'available');
        if (available != null) {
          await txn.update(
            'books',
            <String, Object?>{'status_id': available, 'updated_at': nowStamp()},
            where: 'id = ?',
            whereArgs: <Object?>[bookId],
          );
        }
      }
    });
  }

  // ------------------------------------------------------------------------- //
  // Locations
  // ------------------------------------------------------------------------- //
  @override
  Future<List<Location>> listLocations() async {
    final db = _requireDb();
    final locations = await _locationRows(db);
    return <Location>[
      for (final id in _flattenLocationIds(locations))
        Location.fromJson(
          locationToJson(locations[id]!, fullPath: _fullPath(locations, id)),
        ),
    ];
  }

  @override
  Future<Location> createLocation({
    required String name,
    int? parentId,
    String? kind,
    String? description,
  }) async {
    final db = _requireDb();
    final now = nowStamp();
    final id = await db.insert('locations', <String, Object?>{
      'name': name.trim(),
      'parent_id': _toId(parentId),
      'kind': _blankToNull(kind),
      'description': _blankToNull(description),
      'created_at': now,
      'sync_id': newSyncId(),
      'updated_at': now,
    });
    return _locationById(db, id);
  }

  @override
  Future<Location> updateLocation(
    int id, {
    required String name,
    int? parentId,
    String? kind,
    String? description,
  }) async {
    final db = _requireDb();
    final locations = await _locationRows(db);
    final existing = locations[id];
    if (existing == null) throw ApiNotFoundException(_t('Location not found'));

    final newParent = _toId(parentId);
    // A location may never become its own ancestor.
    if (newParent != null &&
        _descendantIds(locations, id).contains(newParent)) {
      throw ApiValidationException(
        _t('A location cannot be moved inside itself.'),
        statusCode: 400,
      );
    }
    await db.update(
      'locations',
      <String, Object?>{
        'name': name.trim().isEmpty ? existing['name'] : name.trim(),
        'parent_id': newParent,
        // The server leaves these alone when the caller sends nothing.
        if (kind != null) 'kind': _blankToNull(kind),
        if (description != null) 'description': _blankToNull(description),
        'updated_at': nowStamp(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    return _locationById(db, id);
  }

  @override
  Future<bool> deleteLocation(int id) async {
    final db = _requireDb();
    final locations = await _locationRows(db);
    if (!locations.containsKey(id)) {
      throw ApiNotFoundException(_t('Location not found'));
    }
    // Children cascade; books on any of those shelves are simply unshelved.
    // Every shelf that is about to go needs its own tombstone, or the other
    // devices would treat the missing rows as "never created here" and push
    // them straight back.
    await db.transaction((txn) async {
      await _recordTombstones(txn, 'locations', <String?>[
        for (final childId in _descendantIds(locations, id))
          locations[childId]?['sync_id'] as String?,
      ]);
      await txn.delete('locations', where: 'id = ?', whereArgs: <Object?>[id]);
    });
    return true;
  }

  Future<Location> _locationById(DatabaseExecutor db, int id) async {
    final locations = await _locationRows(db);
    final row = locations[id];
    if (row == null) throw ApiNotFoundException(_t('Location not found'));
    return Location.fromJson(
      locationToJson(row, fullPath: _fullPath(locations, id)),
    );
  }

  Future<Map<int, Map<String, Object?>>> _locationRows(
    DatabaseExecutor db,
  ) async {
    return <int, Map<String, Object?>>{
      for (final row in await db.query('locations')) row['id']! as int: row,
    };
  }

  /// ``Living room / Bookshelf A / Top shelf``, walking up the tree.
  String _fullPath(Map<int, Map<String, Object?>> locations, int id) {
    final parts = <String>[];
    var row = locations[id];
    var guard = 0;
    while (row != null && guard < 100) {
      parts.add(row['name']! as String);
      final parent = row['parent_id'] as int?;
      row = parent == null ? null : locations[parent];
      guard++;
    }
    return parts.reversed.join(' / ');
  }

  /// This location's id plus every descendant's.
  List<int> _descendantIds(Map<int, Map<String, Object?>> locations, int id) {
    final children = <int, List<int>>{};
    for (final row in locations.values) {
      final parent = row['parent_id'] as int?;
      if (parent != null) (children[parent] ??= <int>[]).add(row['id']! as int);
    }
    final out = <int>[id];
    final stack = <int>[...?children[id]];
    while (stack.isNotEmpty) {
      final next = stack.removeLast();
      out.add(next);
      stack.addAll(children[next] ?? const <int>[]);
    }
    return out;
  }

  /// Tree order for indented pickers. Roots are ordered by name exactly as the
  /// server's SQL does (byte order); children case-insensitively, as its walk
  /// does.
  List<int> _flattenLocationIds(Map<int, Map<String, Object?>> locations) {
    final children = <int?, List<Map<String, Object?>>>{};
    for (final row in locations.values) {
      (children[row['parent_id'] as int?] ??= <Map<String, Object?>>[]).add(
        row,
      );
    }
    for (final entry in children.entries) {
      if (entry.key == null) {
        entry.value.sort(
          (a, b) => (a['name']! as String).compareTo(b['name']! as String),
        );
      } else {
        entry.value.sort(
          (a, b) => (a['name']! as String).toLowerCase().compareTo(
            (b['name']! as String).toLowerCase(),
          ),
        );
      }
    }
    final out = <int>[];
    void walk(int? parent) {
      for (final child in children[parent] ?? const <Map<String, Object?>>[]) {
        out.add(child['id']! as int);
        walk(child['id']! as int);
      }
    }

    walk(null);
    return out;
  }

  // ------------------------------------------------------------------------- //
  // Statuses
  // ------------------------------------------------------------------------- //
  @override
  Future<List<Status>> listStatuses() async {
    final db = _requireDb();
    final rows = await db.query('statuses', orderBy: 'sort_order, name');
    return rows.map((row) => Status.fromJson(statusToJson(row))).toList();
  }

  @override
  Future<Status> createStatus({
    required String name,
    String color = '#64748b',
    String? icon,
    String? description,
  }) async {
    final db = _requireDb();
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ApiValidationException(
        _t('A status name is required.'),
        statusCode: 400,
      );
    }
    if (await _statusNameExists(db, trimmed)) {
      throw ApiValidationException(
        _tf('A status named “%s” already exists.', <Object?>[trimmed]),
        statusCode: 400,
      );
    }
    final maxOrder =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT MAX(sort_order) FROM statuses'),
        ) ??
        0;
    final id = await db.insert('statuses', <String, Object?>{
      'name': trimmed,
      'slug': await _uniqueStatusSlug(db, slugify(trimmed)),
      'color': color.isEmpty ? '#64748b' : color,
      'icon': _blankToNull(icon),
      'description': _blankToNull(description),
      'sort_order': maxOrder + 10,
      'is_system': 0,
      'is_default': 0,
      'created_at': nowStamp(),
      'sync_id': newSyncId(),
      'updated_at': nowStamp(),
    });
    return _statusById(db, id);
  }

  @override
  Future<Status> updateStatus(
    int id, {
    required String name,
    String color = '#64748b',
    String? icon,
    String? description,
  }) async {
    final db = _requireDb();
    final existing = await _statusRow(db, id);
    if (existing == null) throw ApiNotFoundException(_t('Status not found'));

    final values = <String, Object?>{};
    final trimmed = name.trim();
    if (trimmed.isNotEmpty) {
      final isRename =
          trimmed.toLowerCase() != (existing['name']! as String).toLowerCase();
      if (isRename && await _statusNameExists(db, trimmed, excludeId: id)) {
        throw ApiValidationException(
          _tf('A status named “%s” already exists.', <Object?>[trimmed]),
          statusCode: 400,
        );
      }
      values['name'] = trimmed;
      if (existing['is_system'] != 1 && existing['is_system'] != true) {
        values['slug'] = await _uniqueStatusSlug(
          db,
          slugify(trimmed),
          excludeId: id,
        );
      }
    }
    if (color.trim().isNotEmpty) values['color'] = color.trim();
    values['icon'] = _blankToNull(icon);
    values['description'] = _blankToNull(description);
    values['updated_at'] = nowStamp();

    await db.update(
      'statuses',
      values,
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    return _statusById(db, id);
  }

  @override
  Future<bool> deleteStatus(int id) async {
    final db = _requireDb();
    final existing = await _statusRow(db, id);
    if (existing == null) throw ApiNotFoundException(_t('Status not found'));
    if (existing['is_system'] == 1 || existing['is_system'] == true) {
      throw ApiValidationException(
        _t('System statuses cannot be deleted.'),
        statusCode: 400,
      );
    }
    await db.transaction((txn) async {
      await _recordTombstones(txn, 'statuses', <String?>[
        existing['sync_id'] as String?,
      ]);
      // Whatever was on that status falls back to the default one. The stamp
      // moves with it, so the repointed books travel in the snapshot too.
      final fallback = await _statusBySlug(txn, 'available');
      await txn.update(
        'books',
        <String, Object?>{'status_id': fallback, 'updated_at': nowStamp()},
        where: 'status_id = ?',
        whereArgs: <Object?>[id],
      );
      await txn.delete('statuses', where: 'id = ?', whereArgs: <Object?>[id]);
    });
    return true;
  }

  Future<Map<int, Map<String, Object?>>> _statusRows(
    DatabaseExecutor db,
  ) async {
    return <int, Map<String, Object?>>{
      for (final row in await db.query('statuses')) row['id']! as int: row,
    };
  }

  Future<Map<String, Object?>?> _statusRow(DatabaseExecutor db, int id) async {
    final rows = await db.query(
      'statuses',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Status> _statusById(DatabaseExecutor db, int id) async {
    final row = await _statusRow(db, id);
    if (row == null) throw ApiNotFoundException(_t('Status not found'));
    return Status.fromJson(statusToJson(row));
  }

  Future<int?> _statusBySlug(DatabaseExecutor db, String slug) async {
    final rows = await db.query(
      'statuses',
      where: 'slug = ?',
      whereArgs: <Object?>[slug],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id']! as int;
  }

  /// The status a new book gets: the flagged default, else "In library", else
  /// whatever sorts first.
  Future<int?> _defaultStatusId(DatabaseExecutor db) async {
    final preferred = await db.query(
      'statuses',
      where: 'is_default = 1',
      orderBy: 'sort_order, name',
      limit: 1,
    );
    if (preferred.isNotEmpty) return preferred.first['id']! as int;
    final available = await _statusBySlug(db, 'available');
    if (available != null) return available;
    final first = await db.query(
      'statuses',
      orderBy: 'sort_order, name',
      limit: 1,
    );
    return first.isEmpty ? null : first.first['id']! as int;
  }

  Future<bool> _statusNameExists(
    DatabaseExecutor db,
    String name, {
    int? excludeId,
  }) async {
    final rows = await db.query(
      'statuses',
      where: excludeId == null
          ? 'lower(name) = ?'
          : 'lower(name) = ? AND id != ?',
      whereArgs: excludeId == null
          ? <Object?>[name.toLowerCase()]
          : <Object?>[name.toLowerCase(), excludeId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// ``base``, or ``base-2``/``base-3``… if that slug is taken.
  Future<String> _uniqueStatusSlug(
    DatabaseExecutor db,
    String base, {
    int? excludeId,
  }) async {
    final start = base.isEmpty ? 'status' : base;
    var candidate = start;
    var counter = 1;
    while (true) {
      final rows = await db.query(
        'statuses',
        where: excludeId == null ? 'slug = ?' : 'slug = ? AND id != ?',
        whereArgs: excludeId == null
            ? <Object?>[candidate]
            : <Object?>[candidate, excludeId],
        limit: 1,
      );
      if (rows.isEmpty) return candidate;
      counter++;
      candidate = '$start-$counter';
    }
  }

  // ------------------------------------------------------------------------- //
  // Reference data
  // ------------------------------------------------------------------------- //
  @override
  Future<List<RefItem>> listAuthors() async {
    final db = _requireDb();
    final rows = await db.query('authors', orderBy: 'lower(name)');
    return rows.map(RefItem.fromJson).toList();
  }

  @override
  Future<List<RefItem>> listPublishers() async {
    final db = _requireDb();
    final rows = await db.query('publishers', orderBy: 'lower(name)');
    return rows.map(RefItem.fromJson).toList();
  }

  @override
  Future<List<String>> listSagas() async {
    final db = _requireDb();
    final rows = await db.rawQuery(
      "SELECT DISTINCT saga FROM books WHERE saga IS NOT NULL AND saga != ''",
    );
    final names = rows.map((row) => row['saga']! as String).toList();
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  // ------------------------------------------------------------------------- //
  // Aggregates
  // ------------------------------------------------------------------------- //
  @override
  Future<Stats> stats() async => Stats.fromJson(await _statsJson());

  /// The counters behind [stats], as the ``GET /api/stats`` body.
  Future<Map<String, dynamic>> _statsJson() async {
    final db = _requireDb();
    Future<int> count(String table, {String? where}) async =>
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM $table ${where ?? ''}'),
        ) ??
        0;

    final wishlist = await _statusBySlug(db, 'wishlist');
    return <String, dynamic>{
      'total': await count('books'),
      'authors': await count('authors'),
      'publishers': await count('publishers'),
      // Only loans that are still out.
      'loans': await count('loans', where: 'WHERE returned_at IS NULL'),
      'wishlist': wishlist == null
          ? 0
          : await count('books', where: 'WHERE status_id = $wishlist'),
    };
  }

  @override
  Future<DashboardData> dashboard() async {
    final recent = await _listBooksJson(sort: 'recent');
    final loaned = await _listBooksJson(loaned: 'loaned');

    final counts = await _requireDb().rawQuery(
      'SELECT s.*, COUNT(b.id) AS book_count FROM statuses s'
      ' LEFT JOIN books b ON b.status_id = s.id'
      ' GROUP BY s.id ORDER BY s.sort_order, s.name',
    );

    return DashboardData.fromJson(<String, dynamic>{
      'stats': await _statsJson(),
      'status_counts': <Map<String, dynamic>>[
        for (final row in counts)
          <String, dynamic>{
            'status': statusToJson(row),
            'count': row['book_count'],
          },
      ],
      // The server ships six books here, not the whole catalogue.
      'recent': recent.take(6).toList(),
      'active_loans': <Map<String, dynamic>>[
        for (final book in loaned)
          if (book['active_loan'] != null)
            <String, dynamic>{
              ...(book['active_loan']! as Map<String, dynamic>),
              'book': <String, dynamic>{
                'id': book['id'],
                'title': book['title'],
              },
            },
      ],
    });
  }

  // ------------------------------------------------------------------------- //
  // Reading stats, goals and want-to-read list
  // ------------------------------------------------------------------------- //
  @override
  Future<ReadingStats> personalStats() async {
    final db = _requireDb();
    final shared = await _statsJson();
    final rows = await db.rawQuery(
      'SELECT read_status, page_count, score FROM books',
    );
    final byStatus = <String, int>{};
    var pagesRead = 0;
    final ratings = <double>[];
    for (final row in rows) {
      final status = '${row['read_status'] ?? 'unread'}';
      byStatus[status] = (byStatus[status] ?? 0) + 1;
      if (status == 'read') {
        final pages = _toInt(row['page_count']) ?? 0;
        if (pages > 0) pagesRead += pages;
        final score = (row['score'] as num?)?.toDouble();
        if (score != null) ratings.add(score);
      }
    }
    final total = _toInt(shared['total']) ?? 0;
    final wishlist = _toInt(shared['wishlist']) ?? 0;
    final avg = ratings.isEmpty
        ? null
        : _roundHalfToEven(
                (ratings.reduce((a, b) => a + b) / ratings.length) * 10,
              ) /
              10;
    return ReadingStats.fromJson(<String, dynamic>{
      'total_books': total,
      'in_library': total >= wishlist ? total - wishlist : total,
      'books_read': byStatus['read'] ?? 0,
      'pages_read': pagesRead,
      'avg_rating': avg,
      'currently_reading': byStatus['currently_reading'] ?? 0,
      'loans': shared['loans'],
      'wishlist': wishlist,
      'authors': shared['authors'],
      'status_breakdown': <String, int>{
        for (final key in const <String>[
          'read',
          'currently_reading',
          'dnf',
          'lost',
          'donated',
          'unread',
          'to_read',
        ])
          key: byStatus[key] ?? 0,
      },
    });
  }

  ReadingGoals _cleanGoals(ReadingGoals goals) => ReadingGoals(
    year: goals.year == null || goals.year! <= 0 ? null : goals.year,
    targetBooks: goals.targetBooks < 0 ? 0 : goals.targetBooks,
    targetPages: goals.targetPages < 0 ? 0 : goals.targetPages,
    booksDone: goals.booksDone < 0 ? 0 : goals.booksDone,
    pagesDone: goals.pagesDone < 0 ? 0 : goals.pagesDone,
  );

  /// An objective counts as set only when it has a target to aim at.
  bool _hasTarget(ReadingGoals goals) =>
      goals.targetBooks > 0 || goals.targetPages > 0;

  /// SQL that matches an objective by year, where ``null`` is the "any year"
  /// objective (stored as a null year).
  String _goalYearWhere(int? year) =>
      year == null ? 'year IS NULL' : 'year = ?';
  List<Object?> _goalYearArgs(int? year) =>
      year == null ? const <Object?>[] : <Object?>[year];

  /// Move a device's old ``goals.json`` into the table, once.
  ///
  /// Objectives used to be a side JSON file, which the single-file export
  /// dropped. On the first open of a library that still has that file and an
  /// empty table, copy the objectives across and remove the file so this runs
  /// only once. Old all-time progress is not carried over: a per-objective
  /// counter starts at zero and only moves when a book is marked read.
  Future<void> _migrateLegacyGoals(Database db) async {
    final existing = await db.query('reading_goals');
    if (existing.isNotEmpty) return;
    final file = await _readingFile('goals.json');
    if (!file.existsSync()) return;
    final data = await _readJsonFile(file, const <Object?>[]);
    for (final goal in _parseGoals(data)) {
      if (!_hasTarget(goal)) continue;
      await db.insert(
        'reading_goals',
        <String, Object?>{
          'year': goal.year,
          'target_books': goal.targetBooks,
          'target_pages': goal.targetPages,
          'books_done': 0,
          'pages_done': 0,
        },
      );
    }
    try {
      await file.delete();
    } catch (_) {}
  }

  /// Count a book marked read, toward the objective for the current year and
  /// any "any year" objective. Progress is per objective, so this never touches
  /// the all-time dashboard count.
  Future<void> _recordRead(DatabaseExecutor db, int pages) async {
    final year = DateTime.now().year;
    final rows = await db.query(
      'reading_goals',
      where: 'year = ? OR year IS NULL',
      whereArgs: <Object?>[year],
    );
    for (final row in rows) {
      final booksDone = (row['books_done'] as num?)?.toInt() ?? 0;
      final pagesDone = (row['pages_done'] as num?)?.toInt() ?? 0;
      await db.update(
        'reading_goals',
        <String, Object?>{
          'books_done': booksDone + 1,
          'pages_done': pagesDone + (pages > 0 ? pages : 0),
        },
        where: 'id = ?',
        whereArgs: <Object?>[row['id']],
      );
    }
  }

  /// Read the objectives list, accepting the legacy single-object shape.
  List<ReadingGoals> _parseGoals(Object? data) {
    final raw = data is List
        ? data
        : data is Map
        ? <Object?>[data]
        : const <Object?>[];
    final parsed = <ReadingGoals>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final goal = _cleanGoals(
        ReadingGoals.fromJson(Map<String, dynamic>.from(item)),
      );
      if (_hasTarget(goal)) parsed.add(goal);
    }
    return parsed;
  }

  @override
  Future<List<ReadingGoals>> readingGoals() async {
    final db = _requireDb();
    final rows = await db.query('reading_goals', orderBy: 'year IS NULL, year');
    final goals = <ReadingGoals>[];
    for (final row in rows) {
      final goal = _cleanGoals(
        ReadingGoals(
          year: (row['year'] as num?)?.toInt(),
          targetBooks: (row['target_books'] as num?)?.toInt() ?? 0,
          targetPages: (row['target_pages'] as num?)?.toInt() ?? 0,
          booksDone: (row['books_done'] as num?)?.toInt() ?? 0,
          pagesDone: (row['pages_done'] as num?)?.toInt() ?? 0,
        ),
      );
      if (_hasTarget(goal)) goals.add(goal);
    }
    return goals;
  }

  @override
  Future<void> saveReadingGoals(ReadingGoals goals) async {
    final clean = _cleanGoals(goals);
    final db = _requireDb();
    await db.transaction((txn) async {
      // Replace the objective for this year, or append a new one. An empty
      // objective clears that year. A re-save keeps the progress the existing
      // row for that year already had, so editing a target never resets it.
      final existing = await txn.query(
        'reading_goals',
        where: _goalYearWhere(clean.year),
        whereArgs: _goalYearArgs(clean.year),
      );
      final booksDone = existing.isEmpty
          ? 0
          : (existing.last['books_done'] as num?)?.toInt() ?? 0;
      final pagesDone = existing.isEmpty
          ? 0
          : (existing.last['pages_done'] as num?)?.toInt() ?? 0;
      await txn.delete(
        'reading_goals',
        where: _goalYearWhere(clean.year),
        whereArgs: _goalYearArgs(clean.year),
      );
      if (_hasTarget(clean)) {
        await txn.insert(
          'reading_goals',
          <String, Object?>{
            'year': clean.year,
            'target_books': clean.targetBooks,
            'target_pages': clean.targetPages,
            'books_done': booksDone,
            'pages_done': pagesDone,
          },
        );
      }
    });
  }

  @override
  Future<void> removeReadingGoal(int year) async {
    final db = _requireDb();
    // ``0`` is the sentinel for the "any year" objective, stored as a null year.
    final target = year == 0 ? null : year;
    await db.delete(
      'reading_goals',
      where: _goalYearWhere(target),
      whereArgs: _goalYearArgs(target),
    );
  }

  @override
  Future<List<WantEntry>> wantList() async {
    final file = await _readingFile('want_list.json');
    final data = await _readJsonFile(file, const <Object?>[]);
    if (data is! List) return const [];
    return [
      for (final item in data)
        if (item is Map) WantEntry.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  @override
  Future<void> addWant(WantEntry entry) async {
    await _serialized(() async {
      final file = await _readingFile('want_list.json');
      final data = await _readJsonFile(file, const <Object?>[]);
      final items = <Map<String, dynamic>>[
        if (data is List)
          for (final item in data)
            if (item is Map) Map<String, dynamic>.from(item),
      ];
      final isbn = (entry.isbn ?? '').trim();
      final title = entry.title.trim().toLowerCase();
      if (isbn.isNotEmpty) {
        items.removeWhere((item) => '${item['isbn'] ?? ''}'.trim() == isbn);
      } else if (title.isNotEmpty) {
        items.removeWhere(
          (item) => '${item['title'] ?? ''}'.trim().toLowerCase() == title,
        );
      }
      items.add(entry.toJson());
      await _writeJsonFile(file, items);
    });
  }

  @override
  Future<void> removeWant(String id) async {
    await _serialized(() async {
      final file = await _readingFile('want_list.json');
      final data = await _readJsonFile(file, const <Object?>[]);
      if (data is! List) return;
      await _writeJsonFile(file, <Map<String, dynamic>>[
        for (final item in data)
          if (item is Map && '${item['id'] ?? ''}' != id)
            Map<String, dynamic>.from(item),
      ]);
    });
  }

  @override
  Future<Book> uploadCover(
    int bookId, {
    required String filename,
    required List<int> bytes,
  }) async {
    final db = _requireDb();
    final existing = await _bookRow(db, bookId);
    if (existing == null) throw ApiNotFoundException(_t('Book not found'));
    if (bytes.isEmpty) {
      throw ApiValidationException(_t('That file is empty.'), statusCode: 400);
    }
    if (bytes.length > 10 * 1024 * 1024) {
      throw ApiValidationException(
        _t('That image is too large (the limit is 10 MB).'),
        statusCode: 413,
      );
    }
    final suffix = _sniffImage(bytes);
    if (suffix == null) {
      throw ApiValidationException(
        _t('That file is not a supported image.'),
        statusCode: 400,
      );
    }

    final folder = await _coversFolder();
    final name = 'book-$bookId-${DateTime.now().microsecondsSinceEpoch}$suffix';
    final file = File('${folder.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    final oldUrl = existing['cover_url'] as String?;
    try {
      final book = await updateBook(bookId, <String, dynamic>{
        'cover_url': Uri.file(file.path).toString(),
      });
      await _deleteLocalCover(oldUrl);
      return book;
    } on Object {
      // The row did not take the new URL: remove the orphaned image.
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Future<void> _deleteLocalCover(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'file') return;
    final folder = await _coversFolder();
    final path = uri.toFilePath();
    if (!path.startsWith('${folder.path}${Platform.pathSeparator}')) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  // ------------------------------------------------------------------------- //
  // Online metadata (nothing to do with the local file)
  // ------------------------------------------------------------------------- //
  @override
  Future<SearchResult?> lookupIsbn(String isbn) => _lookup.lookupIsbn(isbn);

  @override
  Future<List<SearchResult>> searchBooks(String query, {int limit = 12}) =>
      _lookup.searchBooks(query, limit: limit);

  // ------------------------------------------------------------------------- //
  // Small shared conversions
  // ------------------------------------------------------------------------- //
  int? _toInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.toInt();
    final text = '$value'.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }

  int? _toId(Object? value) {
    if (value == null) return null;
    final text = '$value'.trim();
    if (text.isEmpty || text == 'none' || text == 'null') return null;
    return _toInt(value);
  }

  /// ``0.5``–``5.0`` stars, snapped to half steps; blank or ``0`` means unrated.
  double? _toScore(Object? value) {
    if (value == null) return null;
    if (value is String && value.trim().isEmpty) return null;
    final score = double.tryParse('$value'.replaceAll(',', '.'));
    if (score == null || score <= 0) return null;
    final snapped = _roundHalfToEven(score / kScoreStep) * kScoreStep;
    if (snapped < kMinScore) return kMinScore;
    if (snapped > kMaxScore) return kMaxScore;
    return snapped;
  }

  /// Python's ``round``: halves go to the *even* neighbour, so 4.25 stars
  /// becomes 4.0 rather than 4.5 — the same answer the server gives.
  double _roundHalfToEven(double value) {
    final floor = value.floorToDouble();
    final fraction = value - floor;
    if (fraction > 0.5) return floor + 1;
    if (fraction < 0.5) return floor;
    return floor % 2 == 0 ? floor : floor + 1;
  }

  /// Python truthiness, which decides whether ``status_id`` counts as supplied.
  bool _isFalsy(Object? value) {
    if (value == null) return true;
    if (value is bool) return !value;
    if (value is num) return value == 0;
    if (value is String) return value.isEmpty;
    if (value is Iterable) return value.isEmpty;
    return false;
  }

  List<String> _splitNames(Object? value) {
    if (value == null) return const <String>[];
    if (value is String) {
      return value
          .split(',')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList();
    }
    if (value is Iterable) {
      return value
          .map((part) => '$part'.trim())
          .where((part) => part.isNotEmpty)
          .toList();
    }
    return const <String>[];
  }

  String? _blankToNull(String? value) {
    final trimmed = (value ?? '').trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
