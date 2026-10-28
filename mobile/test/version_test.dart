import 'dart:io';

import 'package:bibliojules_mobile/src/core/providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// The version shown in the app must match the one in ``pubspec.yaml``.
void main() {
  test('kAppVersion matches the pubspec version', () {
    final versionLine = File(
      'pubspec.yaml',
    ).readAsLinesSync().firstWhere((line) => line.startsWith('version:'));
    final pubspecVersion = versionLine.split(':').last.trim().split('+').first;

    expect(kAppVersion, pubspecVersion);
  });
}
