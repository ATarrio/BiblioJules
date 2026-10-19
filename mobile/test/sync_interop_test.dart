/// The Dart merge and the Python merge, against each other.
///
/// A phone and a server exchange the very same snapshot, so the two
/// implementations of the merge have to agree: a rule only one of them follows
/// would quietly corrupt a library. This builds a library on the phone, hands the
/// snapshot to the server's own sync service, edits the server's copy, and
/// brings it back — checking that neither side duplicated the rows they created
/// independently, and that the newer title won.
///
/// The server half needs the repository's virtualenv, so the test skips itself
/// when it is not there — the same arrangement as ``api_integration_test.dart``.
library;

import 'dart:convert';
import 'dart:io';

import 'package:bibliojules_mobile/src/local/converters.dart';
import 'package:bibliojules_mobile/src/local/local_repo.dart';
import 'package:bibliojules_mobile/src/local/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Runs on the other side of the test: sync the folder, edit a book, report.
const String _serverDriver = r'''
import json, os, sqlite3, sys

sys.path.insert(0, os.environ["PYTHONPATH"])

import app.models  # noqa: E402,F401  (registers every table)
from app.database import Base, SessionLocal, engine, ensure_sync_schema  # noqa: E402
from app.services import seed  # noqa: E402
from app.services import sync as sync_service  # noqa: E402

command, folder = sys.argv[1], sys.argv[2]
path = os.environ["DATABASE_URL"].replace("sqlite:///", "")

# What `python -m app.cli` does before anything else: the tables, the sync
# columns, and the six default statuses.
Base.metadata.create_all(bind=engine)
ensure_sync_schema()
with SessionLocal() as session:
    seed.seed_defaults(session)


def connect():
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    return db


if command == "sync":
    result = sync_service.sync_now(folder, force=True)
    print(json.dumps({
        "pushed": result.pushed,
        "merged": result.merged_snapshot,
        "changes": result.merge.changes if result.merge else 0,
        "device": result.snapshot.device_name,
        "conflicts": result.merge.conflicts if result.merge else [],
    }))
elif command == "edit":
    # What the web app does when somebody edits a book: the row changes and its
    # change stamp moves forward.
    db = connect()
    db.execute(
        "UPDATE books SET title = ?, updated_at = ? WHERE isbn = ?",
        ("Dune (edited on the server)", sys.argv[3], "9780441013593"),
    )
    db.commit()
    print(json.dumps({"edited": db.total_changes}))
elif command == "report":
    db = connect()
    out = {}
    for table in ("books", "authors", "publishers", "statuses", "locations", "loans"):
        out[table] = [dict(row) for row in db.execute(f"SELECT * FROM {table}")]
    print(json.dumps(out))
else:
    raise SystemExit(f"unknown command: {command}")
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final python = File('../.venv/bin/python');
  final repositoryRoot = Directory.current.parent.absolute.path;
  final missingVenv = python.existsSync() ? null : 'the repository venv is not installed';

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory root;
  late Directory shared;
  late Directory documents;
  late File serverDatabase;
  late File driver;
  late LocalRepo repo;
  late LibrarySync sync;

  /// Run one of the driver's subcommands, and fail loudly when it does.
  Future<Map<String, Object?>> server(List<String> arguments) async {
    final result = await Process.run(
      python.absolute.path,
      <String>[driver.path, ...arguments],
      environment: <String, String>{
        'PYTHONPATH': repositoryRoot,
        'DATABASE_URL': 'sqlite:///${serverDatabase.path}',
        'SECRET_KEY': 'interop-test',
      },
    );
    if (result.exitCode != 0) {
      fail('the server side failed: ${result.stderr}');
    }
    final text = '${result.stdout}'.trim().split('\n').last;
    return (jsonDecode(text) as Map).cast<String, Object?>();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bibliojules_interop');
    shared = Directory('${root.path}/shared')..createSync();
    documents = Directory('${root.path}/documents')..createSync();
    serverDatabase = File('${root.path}/server.db');
    driver = File('${root.path}/driver.py')..writeAsStringSync(_serverDriver);
    repo = LocalRepo(documentsDirectory: () async => documents);
    await repo.open('My library');
    sync = LibrarySync(
      repo: repo,
      transport: FolderSyncTransport(shared),
      scratchDirectory: () async => Directory('${root.path}/scratch')..createSync(),
    );
  });

  tearDown(() async {
    await repo.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a phone snapshot and a server merge meet in the middle', () async {
    // The phone's library: a book, its author, a shelf and a loan.
    final shelf = await repo.createLocation(name: 'Living room', kind: 'Room');
    final book = await repo.createBook({
      'title': 'Dune',
      'authors': ['Frank Herbert'],
      'publisher': 'Chilton',
      'isbn': '9780441013593',
      'location_id': shelf.id,
    });
    await repo.lendBook(book.id, borrowerName: 'Ada');
    final published = await sync.run();
    expect(published.pushed, isTrue);
    expect(published.merge, isNull, reason: 'nothing was there to merge');

    // The server picks it up. It has its own six statuses, so this is also the
    // first-contact test: they must be married by slug, not duplicated.
    final first = await server(<String>['sync', shared.path]);
    expect(first['merged'], isTrue);
    expect(first['changes'], greaterThan(0));
    final serverDevice = '${first['device']}';
    expect(serverDevice, isNotEmpty);

    var report = await server(<String>['report', shared.path]);
    expect((report['books']! as List).length, 1);
    expect((report['authors']! as List).length, 1);
    expect((report['publishers']! as List).length, 1);
    expect((report['statuses']! as List).length, 6);
    expect((report['locations']! as List).length, 1);
    expect((report['loans']! as List).length, 1);

    // Somebody edits the book in the browser. The stamp has to be later than the
    // one the phone wrote, and a second is the smallest honest step.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final stamp = nowStamp();
    final edited = await server(<String>['edit', shared.path, stamp]);
    expect(edited['edited'], 1);
    await server(<String>['sync', shared.path]);

    // The phone merges it back: the server's newer title wins, the rows it
    // already had are not duplicated, and the snapshot says who wrote it.
    final merged = await sync.run();
    expect(merged.mergedSnapshot, isTrue);
    expect(merged.merge!.sourceDevice, serverDevice);
    expect((await repo.listBooks()).single.title, 'Dune (edited on the server)');
    expect((await repo.listAuthors()).length, 1);
    expect((await repo.listPublishers()).length, 1);
    expect((await repo.listStatuses()).length, 6);
    expect((await repo.listLocations()).length, 1);
    expect((await repo.bookLoans(book.id)).length, 1);
    expect(merged.merge!.conflicts, isEmpty);

    // And the server is unchanged by that: one of everything, still.
    report = await server(<String>['report', shared.path]);
    expect((report['books']! as List).length, 1);
    expect((report['statuses']! as List).length, 6);
  }, skip: missingVenv);

  test('a delete made on the phone is obeyed by the server', () async {
    final doomed = await repo.createBook({'title': 'Doomed'});
    await repo.createBook({'title': 'Kept'});
    await sync.run();
    await server(<String>['sync', shared.path]);

    await repo.deleteBook(doomed.id);
    await sync.run();
    await server(<String>['sync', shared.path]);

    final report = await server(<String>['report', shared.path]);
    final titles = <String>[
      for (final row in report['books']! as List)
        '${(row as Map)['title']}',
    ];
    expect(titles, ['Kept']);
  }, skip: missingVenv);
}
