/// Handing a library file to the system's file picker, and taking one back.
///
/// Android never gives an app a plain path to wherever the user chooses to put
/// things: the answer is a ``content://`` URI owned by another app (Downloads,
/// Google Drive, a USB stick). So the byte-shuffling happens in Kotlin —
/// ``MainActivity.kt``, on the other side of this channel — while every
/// decision stays here: what a snapshot of the library is, and whether a picked
/// file is one we can read.
///
/// That split keeps the interesting logic testable on a desktop: the tests
/// stand in for the channel.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api_exception.dart';
import 'converters.dart';
import 'library_files.dart';
import 'local_repo.dart';

/// The channel ``MainActivity.kt`` listens on.
const String kFilesChannel = 'bibliojules/files';

/// The scratch file a snapshot is written to before the picker takes it.
const String kExportFileName = 'export.sqlite';

/// The scratch file a picked document is copied into while it is validated.
const String kImportFileName = 'import.sqlite';

class LibraryTransfer {
  LibraryTransfer({
    required this.repo,
    MethodChannel? channel,
    Future<Directory> Function()? scratchDirectory,
  }) : _channel = channel ?? const MethodChannel(kFilesChannel),
       _scratchDirectory = scratchDirectory ?? getTemporaryDirectory;

  /// The library being moved, which must be open.
  final LocalRepo repo;

  final MethodChannel _channel;
  final Future<Directory> Function() _scratchDirectory;

  /// Ask where to put a copy of the open library, and write it there.
  ///
  /// Returns the name the destination storage shows (for a thankyou message), or
  /// ``null`` when the user backs out of the picker.
  Future<String?> exportLibrary() async {
    if (!repo.isOpen) {
      throw ApiException('No local library is open.');
    }

    final scratch = await _scratch();
    final name = repo.libraryName ?? kDefaultLibraryName;
    final source = File('${scratch.path}${Platform.pathSeparator}$kExportFileName');
    // VACUUM INTO refuses to overwrite, so anything left by an earlier crash
    // has to go first. Both of these are best-effort tidying in the app's own
    // cache directory: nothing depends on them succeeding.
    if (source.existsSync()) source.deleteSync();

    await repo.exportTo(source);
    try {
      final String? saved;
      try {
        saved = await _channel.invokeMethod<String>('export', <String, Object?>{
          'source': source.path,
          // A name that says what this is and when it was taken, so a Drive
          // folder with several exports in it stays readable.
          'name': '${librarySlug(name)}-${todayDate()}.sqlite',
        });
      } on PlatformException catch (error) {
        throw ApiException(
          error.message ?? 'The library could not be exported.',
        );
      }
      return saved;
    } finally {
      if (source.existsSync()) source.deleteSync();
    }
  }

  /// Ask for a file and, once it validates, make it this device's library.
  ///
  /// Returns the library's name afterwards, or ``null`` when the user backs out.
  /// The library that was open is gone either way: nothing is merged.
  Future<String?> importLibrary() async {
    final scratch = await _scratch();
    final target = File('${scratch.path}${Platform.pathSeparator}$kImportFileName');
    if (target.existsSync()) target.deleteSync();

    final String? path;
    try {
      path = await _channel.invokeMethod<String>('pick', <String, Object?>{
        'target': target.path,
      });
    } on PlatformException catch (error) {
      throw ApiException(error.message ?? 'That file could not be read.');
    }
    if (path == null) return null;

    final picked = File(path);
    try {
      // Throws (and keeps the current library) when the file is not one of ours.
      await repo.importFrom(picked);
      return repo.libraryName;
    } finally {
      // The import has already committed, so this is only tidying.
      if (picked.existsSync()) picked.deleteSync();
    }
  }

  Future<Directory> _scratch() async {
    final folder = await _scratchDirectory();
    if (!folder.existsSync()) folder.createSync(recursive: true);
    return folder;
  }
}
