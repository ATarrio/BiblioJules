/// The two places where sqflite on Android and the FFI build the tests run on
/// disagree — both learned the hard way, from a phone.
///
/// ``Database.execute`` maps to Android's ``execSQL``, which takes a single
/// statement and only if it returns no rows. ``package:sqflite_common_ffi``,
/// which every other test here runs against, executes anything. So:
///
/// * a pragma that answers with a row — ``wal_checkpoint``, ``journal_mode``,
///   ``integrity_check``, ``foreign_key_check``… — has to go through
///   ``rawQuery``. ``PRAGMA wal_checkpoint(TRUNCATE)`` through ``execute``
///   exported and synced happily in the test suite and threw
///   *"Queries can be performed using SQLiteDatabase query or rawQuery methods
///   only"* the first time it ran on a phone;
/// * a raw ``BEGIN``/``COMMIT``/``ROLLBACK`` must not be executed by hand: the
///   Android driver records the open transaction and then queues every later
///   call from that handle, the commit included, so it waits for the
///   transaction that is waiting for it. ``db.transaction(...)`` is the form
///   that starts a write transaction, commits, and rolls back on a throw.
///
/// Scanning the sources is the only way to notice either from a test host.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every Dart file that ships in the app.
Iterable<File> _sources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'));

class _Executed {
  _Executed(this.sql, this.line);

  final String sql;

  /// 1-based, so the failure points at the file.
  final int line;
}

/// Literal SQL handed to ``.execute('…')`` or ``.execute("…")``.
Iterable<_Executed> _executed(String text) sync* {
  final call = RegExp(r'''\.execute\(\s*(?:'([^']*)'|"([^"]*)")''');
  for (final match in call.allMatches(text)) {
    final sql = match.group(1) ?? match.group(2) ?? '';
    final line = '\n'.allMatches(text.substring(0, match.start)).length + 1;
    yield _Executed(sql, line);
  }
}

/// True for the pragmas that answer with nothing, and so may be executed.
///
/// Setting ``user_version`` and turning ``foreign_keys`` on are the two the app
/// uses; anything else that starts with ``PRAGMA`` is a query.
bool _answerless(String sql) {
  final text = sql.trim().toUpperCase();
  return text.startsWith('PRAGMA FOREIGN_KEYS =') ||
      text.startsWith('PRAGMA USER_VERSION =');
}

void main() {
  test('a pragma that answers with rows is queried, not executed', () {
    final offenders = <String>[];
    for (final file in _sources()) {
      for (final call in _executed(file.readAsStringSync())) {
        final sql = call.sql.trim();
        if (!sql.toUpperCase().startsWith('PRAGMA')) continue;
        if (_answerless(sql)) continue;
        offenders.add('${file.path}:${call.line}  $sql');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Android\'s execute() refuses statements that return rows, but the\n'
          'FFI build used by these tests accepts them, so this only fails on a\n'
          'phone. Use rawQuery() for these:\n  ${offenders.join('\n  ')}',
    );
  });

  test('transactions go through sqflite, never through raw BEGIN/COMMIT', () {
    const control = <String>{
      'BEGIN',
      'COMMIT',
      'END',
      'ROLLBACK',
      'SAVEPOINT',
      'RELEASE',
    };
    final offenders = <String>[];
    for (final file in _sources()) {
      for (final call in _executed(file.readAsStringSync())) {
        final first = call.sql.trim().split(RegExp(r'[\s;]')).first.toUpperCase();
        if (!control.contains(first)) continue;
        offenders.add('${file.path}:${call.line}  ${call.sql.trim()}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Android\'s sqflite queues every later call from a handle while a\n'
          'transaction opened with raw SQL is pending — the commit included — so\n'
          'this works on the FFI build and hangs on a phone. Use\n'
          'db.transaction((txn) async { … }) instead:\n  '
          '${offenders.join('\n  ')}',
    );
  });
}
