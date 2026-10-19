/// Getting a library out of the app's private storage, and back in.
///
/// The Android half (``MainActivity.kt``) cannot run here, so the system picker
/// is stood in for by a mocked method channel: the tests decide what the user
/// "picked", and the real work — the snapshot, the validation, the swap — runs
/// for real against a real SQLite file.
library;

import 'dart:io';

import 'package:bibliojules_mobile/src/core/api_exception.dart';
import 'package:bibliojules_mobile/src/local/local_repo.dart';
import 'package:bibliojules_mobile/src/local/schema.dart';
import 'package:bibliojules_mobile/src/local/transfer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The real server's database, used to prove the migration path when it happens
/// to be present (it is a working copy, not test data).
final _serverDatabase = File('../data/library.db');

const _channel = MethodChannel(kFilesChannel);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory documents;
  late Directory scratch;
  late LocalRepo repo;

  /// Answer the next ``export``/``pick`` call with [handler].
  void onChannel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, handler);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null),
    );
  }

  LocalRepo libraryIn(Directory folder) =>
      LocalRepo(documentsDirectory: () async => folder);

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('bibliojules_docs');
    scratch = await Directory.systemTemp.createTemp('bibliojules_scratch');
    repo = libraryIn(documents);
    await repo.open('Mi biblioteca');
  });

  tearDown(() async {
    await repo.dispose();
    for (final folder in [documents, scratch]) {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    }
  });

  group('the snapshot', () {
    test('is a complete library that opens on its own', () async {
      await repo.createBook({
        'title': 'Dune',
        'authors': ['Frank Herbert'],
        'read_status': 'read',
        'score': 4.5,
      });
      await repo.createBook({'title': 'Ubik', 'saga': 'Valis', 'saga_number': 2});

      final snapshot = File('${scratch.path}/dune.sqlite');
      await repo.exportTo(snapshot);
      expect(snapshot.existsSync(), isTrue);

      // A second device: its own folder, its own library, then the import.
      final other = await Directory.systemTemp.createTemp('bibliojules_other');
      addTearDown(() => other.deleteSync(recursive: true));
      final elsewhere = libraryIn(other);
      addTearDown(elsewhere.dispose);
      await elsewhere.open('Otra biblioteca');
      await elsewhere.importFrom(snapshot);

      final books = await elsewhere.listBooks(sort: 'title');
      expect(books.map((book) => book.title), ['Dune', 'Ubik']);
      expect(books.first.score, 4.5);
      expect(books.first.authors, ['Frank Herbert']);
      expect(books.last.sagaNumber, 2);
      // The shelf labels travelled too, renamed and all.
      expect((await elsewhere.listStatuses()).length, 6);
      expect(elsewhere.libraryName, 'Otra biblioteca');
    });

    test('is written even when the library has been renamed', () async {
      await repo.renameTo('Biblioteca de Ana');
      final snapshot = File('${scratch.path}/renamed.sqlite');
      await repo.exportTo(snapshot);
      expect(snapshot.lengthSync(), greaterThan(0));
    });
  });

  group('validation', () {
    test('a file that is not a database is refused', () async {
      final junk = File('${scratch.path}/junk.sqlite');
      await junk.writeAsString('this is not a database, it is a shopping list');

      await expectLater(
        () => repo.importFrom(junk),
        throwsA(
          isA<ApiValidationException>().having(
            (error) => error.message,
            'message',
            contains('not a BiblioJules library'),
          ),
        ),
      );
      // And the library that was open is still the one on disk.
      expect((await repo.listBooks()), isEmpty);
      expect(repo.isOpen, isTrue);
      expect(repo.libraryName, 'Mi biblioteca');
    });

    test('an empty file is refused', () async {
      final empty = File('${scratch.path}/empty.sqlite')..createSync();
      await expectLater(
        () => repo.importFrom(empty),
        throwsA(
          isA<ApiValidationException>().having(
            (error) => error.message,
            'message',
            contains('empty'),
          ),
        ),
      );
    });

    test('a database missing our tables is refused', () async {
      final stranger = File('${scratch.path}/stranger.sqlite');
      final db = await databaseFactory.openDatabase(stranger.path);
      await db.execute('CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT)');
      await db.insert('books', {'title': 'Something else'});
      await db.close();

      await expectLater(
        () => repo.importFrom(stranger),
        throwsA(
          isA<ApiValidationException>().having(
            (error) => error.message,
            'message',
            contains('not a BiblioJules library'),
          ),
        ),
      );
    });

    test('a database from the future is refused', () async {
      final future = File('${scratch.path}/future.sqlite');
      final db = await databaseFactory.openDatabase(future.path);
      for (final statement in kLibrarySchemaStatements) {
        await db.execute(statement);
      }
      await db.execute('PRAGMA user_version = 99');
      await db.close();

      await expectLater(
        () => repo.importFrom(future),
        throwsA(
          isA<ApiValidationException>().having(
            (error) => error.message,
            'message',
            contains('newer version'),
          ),
        ),
      );
    });
  });

  group('importing a server database', () {
    /// A database shaped like the hosted app's: our tables, plus accounts and
    /// tokens, and no schema version at all (the server does not use one).
    Future<File> serverShaped(Directory folder) async {
      final file = File('${folder.path}/server.sqlite');
      final db = await databaseFactory.openDatabase(file.path);
      for (final statement in kLibrarySchemaStatements) {
        await db.execute(statement);
      }
      await db.execute(
        'CREATE TABLE users (id INTEGER PRIMARY KEY, username VARCHAR(80) NOT NULL UNIQUE)',
      );
      await db.execute(
        'CREATE TABLE tokens (id INTEGER PRIMARY KEY, token VARCHAR(64) NOT NULL)',
      );
      await db.insert('users', {'username': 'ana'});
      await db.insert('statuses', {
        'id': 1,
        'name': 'In library',
        'slug': 'available',
        'color': '#22c55e',
        'sort_order': 10,
        'is_system': 1,
        'is_default': 1,
        'created_at': '2024-01-01 00:00:00.000000',
      });
      await db.insert('books', {
        'title': 'Dune',
        'read_status': 'read',
        'score': 5.0,
        'status_id': 1,
        'created_at': '2024-01-01 00:00:00.000000',
        'updated_at': '2024-01-01 00:00:00.000000',
      });
      await db.close();
      return file;
    }

    test('extra tables and no schema version are fine', () async {
      final server = await serverShaped(scratch);
      // The file has never been stamped, so sqflite would treat it as brand new
      // if the import did not do it first.
      final probe = await databaseFactory.openDatabase(server.path);
      final version =
          (await probe.rawQuery('PRAGMA user_version')).first.values.first;
      await probe.close();
      expect(version, 0);

      await repo.importFrom(server);

      final books = await repo.listBooks();
      expect(books.single.title, 'Dune');
      expect(books.single.score, 5.0);
      expect(books.single.status?.slug, 'available');
      // And the stamped version means the *next* open does no creating.
      await repo.close();
      await repo.open('Mi biblioteca');
      expect((await repo.listBooks()).single.title, 'Dune');
    }, skip: false);

    test('a server database dropped into place by hand is stamped on open',
        () async {
      // The other way a file gets in: copied over adb or out of a Drive folder
      // straight into the app's storage, with no import in between.
      final server = await serverShaped(scratch);
      final target = await repo.libraryFile('Mi biblioteca');
      await repo.close();
      await server.copy(target.path);

      await repo.open('Mi biblioteca');

      expect((await repo.listBooks()).single.title, 'Dune');
    });

    test('the real data/library.db imports when it is around', () async {
      if (!_serverDatabase.existsSync()) {
        markTestSkipped('no ${_serverDatabase.path} to import');
        return;
      }
      // Copy first: the test must not touch the server's own file.
      final copy = await _serverDatabase.copy('${scratch.path}/real.sqlite');
      await repo.importFrom(copy);

      final books = await repo.listBooks();
      expect(books, isNotEmpty);
      for (final book in books) {
        expect(book.title, isNotEmpty);
      }
      // The server's default statuses came along, so lending still works.
      final statuses = await repo.listStatuses();
      expect(statuses.any((status) => status.isDefault), isTrue);
    }, skip: _serverDatabase.existsSync() ? false : 'no server database present');
  });

  group('through the picker', () {
    test('export hands the snapshot over and tidies up after itself', () async {
      await repo.createBook({'title': 'Dune'});
      File? seen;
      List<String>? arguments;
      onChannel((call) async {
        expect(call.method, 'export');
        arguments = [call.arguments['name'] as String];
        // The file must exist *while* the picker is writing it out.
        seen = File(call.arguments['source'] as String);
        expect(seen!.existsSync(), isTrue);
        expect(seen!.lengthSync(), greaterThan(0));
        return 'Biblioteca de Ana.sqlite';
      });

      final transfer = LibraryTransfer(repo: repo, scratchDirectory: () async => scratch);
      final saved = await transfer.exportLibrary();
      expect(saved, 'Biblioteca de Ana.sqlite');
      // Named after the library and dated, so a folder of exports stays legible.
      expect(arguments!.single, startsWith('mi-biblioteca-'));
      expect(arguments!.single, endsWith('.sqlite'));
      // The scratch copy does not linger in the cache directory.
      expect(seen!.existsSync(), isFalse);
    });

    test('export reports a cancel as nothing saved', () async {
      onChannel((call) async => null);
      final transfer = LibraryTransfer(repo: repo, scratchDirectory: () async => scratch);
      expect(await transfer.exportLibrary(), isNull);
      expect(scratch.listSync().whereType<File>(), isEmpty);
    });

    test('a refusal from the platform becomes a readable error', () async {
      onChannel(
        (call) async => throw PlatformException(
          code: 'transfer_failed',
          message: 'That folder cannot be written to.',
        ),
      );
      final transfer = LibraryTransfer(repo: repo, scratchDirectory: () async => scratch);
      await expectLater(
        transfer.exportLibrary(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            'That folder cannot be written to.',
          ),
        ),
      );
      expect(scratch.listSync().whereType<File>(), isEmpty);
    });

    test('import swaps the library for the picked file', () async {
      // A library that is not this one, so the change is unmistakable.
      final source = libraryIn(scratch);
      await source.open('Otra biblioteca');
      await source.createBook({'title': 'Solaris'});
      final snapshot = File('${scratch.path}/solaris.sqlite');
      await source.exportTo(snapshot);
      await source.dispose();

      onChannel((call) async {
        expect(call.method, 'pick');
        final target = File(call.arguments['target'] as String);
        await snapshot.copy(target.path);
        return target.path;
      });

      final transfer = LibraryTransfer(repo: repo, scratchDirectory: () async => scratch);
      expect(await transfer.importLibrary(), 'Mi biblioteca');
      expect((await repo.listBooks()).single.title, 'Solaris');
      // The scratch copy of the picked file is gone.
      expect(
        scratch.listSync().whereType<File>().map((file) => file.uri.pathSegments.last),
        isNot(contains(kImportFileName)),
      );
    });

    test('import reports a cancel, leaving the library alone', () async {
      await repo.createBook({'title': 'Dune'});
      onChannel((call) async => null);
      final transfer = LibraryTransfer(repo: repo, scratchDirectory: () async => scratch);
      expect(await transfer.importLibrary(), isNull);
      expect((await repo.listBooks()).single.title, 'Dune');
    });

    test('import refuses a file the user mis-picked, and keeps the library',
        () async {
      await repo.createBook({'title': 'Dune'});
      onChannel((call) async {
        final target = File(call.arguments['target'] as String);
        await target.writeAsString('definitely not a database');
        return target.path;
      });
      final transfer = LibraryTransfer(repo: repo, scratchDirectory: () async => scratch);
      await expectLater(
        transfer.importLibrary(),
        throwsA(isA<ApiValidationException>()),
      );
      expect((await repo.listBooks()).single.title, 'Dune');
    });
  });
}
