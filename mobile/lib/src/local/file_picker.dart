/// Opening the Android document picker for a single file (CSV, image…).
///
/// The picker itself lives in ``MainActivity.kt``, on the same channel as the
/// library import/export. Android returns a ``content://`` URI, Kotlin copies
/// it to a scratch file, and Dart gets a path it can read.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api_exception.dart';
import 'transfer.dart';

class DeviceFilePicker {
  DeviceFilePicker({
    MethodChannel? channel,
    Future<Directory> Function()? scratchDirectory,
  }) : _channel = channel ?? const MethodChannel(kFilesChannel),
       _scratchDirectory = scratchDirectory ?? getTemporaryDirectory;

  final MethodChannel _channel;
  final Future<Directory> Function() _scratchDirectory;

  /// Ask for one file, copied into the app's cache.
  ///
  /// Returns ``null`` when the user backs out. [mimeType] is only a hint for
  /// the picker; the caller still validates the bytes it receives.
  Future<File?> pick({required String name, String mimeType = '*/*'}) async {
    final folder = await _scratchDirectory();
    if (!folder.existsSync()) await folder.create(recursive: true);
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final target = File(
      '${folder.path}${Platform.pathSeparator}'
      '${DateTime.now().microsecondsSinceEpoch}-$safe',
    );
    if (await target.exists()) await target.delete();
    try {
      final path = await _channel.invokeMethod<String>(
        'pick',
        <String, Object?>{'target': target.path, 'type': mimeType},
      );
      return path == null ? null : File(path);
    } on PlatformException catch (error) {
      throw ApiException(error.message ?? 'That file could not be read.');
    }
  }
}
