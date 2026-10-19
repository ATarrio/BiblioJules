import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app bundles copies of the server's string catalogues (see pubspec.yaml).
/// If someone edits one, this test fails so the other gets updated too.
void main() {
  test('bundled catalogues are identical to the server\'s', () {
    final appLocales = Directory('../app/locales');
    final bundled = Directory('assets/locales');

    expect(
      appLocales.existsSync(),
      isTrue,
      reason: 'run this test from the mobile/ directory',
    );
    expect(bundled.existsSync(), isTrue);

    final source = appLocales
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .where((name) => name.endsWith('.json'))
        .toList()
      ..sort();

    final copies = bundled
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .where((name) => name.endsWith('.json'))
        .toList()
      ..sort();

    expect(
      copies,
      source,
      reason:
          'assets/locales must mirror app/locales; copy any missing file with '
          '`cp ../app/locales/<name>.json assets/locales/`',
    );

    for (final name in source) {
      expect(
        File('assets/locales/$name').readAsStringSync(),
        File('../app/locales/$name').readAsStringSync(),
        reason: 'assets/locales/$name is out of date',
      );
    }
  });
}
