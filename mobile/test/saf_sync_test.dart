/// Syncing through an Android folder grant.
///
/// ``MainActivity.kt`` cannot run here, so the system folder picker is stood in
/// for by a mocked method channel: the "granted folder" is a real directory, and
/// `syncPull`/`syncPush` copy the snapshot exactly as Kotlin does. Everything
/// else — the merge, the snapshot header, the state file — is the real thing.
library;

import 'dart:io';

import 'package:bibliojules_mobile/src/local/local_repo.dart';
import 'package:bibliojules_mobile/src/local/sync.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The channel ``MainActivity.kt`` listens on.
const _channel = MethodChannel(kFilesChannel);

/// What Android calls the folder the user picked.
const _folderUri = 'content://com.android.externalstorage.documents/tree/primary%3ABiblioJules';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory root;
  late Directory shared;
  late Directory docsA;
  late Directory docsB;
  late LocalRepo repoA;
  late LocalRepo repoB;
  late File snapshot;

  /// Answer channel calls as Android does, with [shared] as the granted folder.
  void grantFolder({
    bool writable = true,
    bool readable = true,
    String? name = 'BiblioJules',
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
          switch (call.method) {
            case 'pickSyncFolder':
              return <Object?, Object?>{'uri': _folderUri, 'name': name};
            case 'syncFolderName':
              return name;
            case 'syncPermission':
              return writable;
            case 'syncPull':
              if (!readable) {
                throw PlatformException(
                  code: 'transfer_failed',
                  message: 'That folder cannot be read.',
                );
              }
              // Kotlin copies the document out to a file in the app's cache.
              if (!snapshot.existsSync()) return false;
              snapshot.copySync(args['target']! as String);
              return true;
            case 'syncPush':
              if (!writable) {
                throw PlatformException(
                  code: 'transfer_failed',
                  message: 'The shared folder cannot be written to.',
                );
              }
              snapshot.writeAsBytesSync(
                File(args['source']! as String).readAsBytesSync(),
              );
              return true;
            default:
              return null;
          }
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null),
    );
  }

  LibrarySync syncOf(LocalRepo repo, Directory scratch) => LibrarySync(
    repo: repo,
    transport: SafSyncTransport(folderUri: _folderUri, channel: _channel),
    scratchDirectory: () async => scratch,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bibliojules_saf');
    shared = Directory('${root.path}/shared')..createSync();
    snapshot = File('${shared.path}${Platform.pathSeparator}$kSnapshotName');
    docsA = Directory('${root.path}/a')..createSync();
    docsB = Directory('${root.path}/b')..createSync();
    repoA = LocalRepo(documentsDirectory: () async => docsA);
    await repoA.open('A library');
    repoB = LocalRepo(documentsDirectory: () async => docsB);
    await repoB.open('B library');
    grantFolder();
  });

  tearDown(() async {
    await repoA.dispose();
    await repoB.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('the picker hands back a folder this device can keep using', () async {
    final picker = SharedFolder(channel: _channel);
    final choice = await picker.choose();
    expect(choice, isNotNull);
    expect(choice!.uri, _folderUri);
    expect(choice.name, 'BiblioJules');
    expect(await picker.canWrite(_folderUri), isTrue);
    expect(await picker.nameOf(_folderUri), 'BiblioJules');
  });

  test('backing out of the picker says nothing happened', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async => null);
    expect(await SharedFolder(channel: _channel).choose(), isNull);
  });

  test('a snapshot travels in and out through the folder grant', () async {
    // B publishes first, through a plain folder (its own device).
    await repoB.createBook({'title': 'Ubik', 'authors': ['Philip K. Dick']});
    final byFolder = LibrarySync(
      repo: repoB,
      transport: FolderSyncTransport(shared),
      scratchDirectory: () async => Directory('${root.path}/scratchB')..createSync(),
    );
    expect((await byFolder.run()).pushed, isTrue);
    expect(snapshot.existsSync(), isTrue);

    // A is a phone: it reaches the same folder through a content:// URI.
    await repoA.createBook({'title': 'Dune'});
    final result = await syncOf(repoA, Directory('${root.path}/scratchA')..createSync()).run();

    expect(result.mergedSnapshot, isTrue);
    expect(result.merge!.added['books'], 1);
    expect(
      (await repoA.listBooks(sort: 'title')).map((book) => book.title),
      ['Dune', 'Ubik'],
    );
    // A had something the snapshot did not, so it wrote one back.
    expect(result.pushed, isTrue);
    final published = await readSnapshotMeta(snapshot);
    expect(published.deviceName, isNotEmpty);
    expect(published.generation, greaterThan(result.merge!.sourceGeneration));

    // ... and B, on its next sync, sees A's book.
    final back = await byFolder.run();
    expect(back.mergedSnapshot, isTrue);
    expect(
      (await repoB.listBooks(sort: 'title')).map((book) => book.title),
      ['Dune', 'Ubik'],
    );
  });

  test('the first sync anywhere publishes this library', () async {
    await repoA.createBook({'title': 'Dune'});
    final result = await syncOf(repoA, Directory('${root.path}/scratchA')..createSync()).run();
    expect(result.pushed, isTrue);
    expect(result.mergedSnapshot, isFalse);
    expect(snapshot.existsSync(), isTrue);
    expect((await readSnapshotMeta(snapshot)).generation, 1);
  });

  test('a folder Android has forgotten is reported, not swallowed', () async {
    grantFolder(readable: false);
    await repoA.createBook({'title': 'Dune'});
    await expectLater(
      syncOf(repoA, Directory('${root.path}/scratchA')..createSync()).run(),
      throwsA(
        isA<SyncException>().having(
          (error) => error.message,
          'message',
          contains('cannot be read'),
        ),
      ),
    );
    // The library is untouched by a sync that could not even read.
    expect((await repoA.listBooks()).length, 1);
  });

  test('a folder that cannot be written to fails after the merge', () async {
    await repoB.createBook({'title': 'Ubik'});
    await LibrarySync(
      repo: repoB,
      transport: FolderSyncTransport(shared),
      scratchDirectory: () async => Directory('${root.path}/scratchB')..createSync(),
    ).run();

    await repoA.createBook({'title': 'Dune'});
    grantFolder(writable: false);
    await expectLater(
      syncOf(repoA, Directory('${root.path}/scratchA')..createSync()).run(),
      throwsA(
        isA<SyncException>().having(
          (error) => error.message,
          'message',
          contains('cannot be written to'),
        ),
      ),
    );
    // The merge itself already happened, and it is the merge that mattered.
    expect((await repoA.listBooks(sort: 'title')).map((b) => b.title), ['Dune', 'Ubik']);
  });
}
