/// Fails when the phone's copy of the schema drifts from the server's.
///
/// ``mobile/lib/src/local/schema.dart`` is a hand-kept copy of ``app/models/``:
/// the phone has to be able to run without a server, and it has to be able to
/// swap files with one — so the two schemas are not allowed to disagree about a
/// table or a column. Rather than trust that, the server's own layout is dumped
/// by ``dump_schema.py`` into ``test/fixtures/server_schema.json`` and compared
/// here. Add a column to a model without copying it over and this fails.
///
/// Accounts are the one deliberate difference: ``users`` and ``tokens`` only
/// exist where something is doing the authenticating.
library;

import 'dart:convert';
import 'dart:io';

import 'package:bibliojules_mobile/src/local/schema.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tables the phone does not need, because it never signs anyone in.
const _accounts = {'users', 'tokens'};

/// The tables and columns declared by [kLibrarySchemaStatements].
///
/// Parsed from the SQL itself rather than from a second list, so this checks
/// what the app will really create and cannot fall out of step with it.
Map<String, Set<String>> _tablesFromDdl() {
  final tables = <String, Set<String>>{};
  for (final statement in kLibrarySchemaStatements) {
    final match = RegExp(
      r'^\s*CREATE TABLE\s+(\w+)\s*\(',
      caseSensitive: false,
    ).firstMatch(statement);
    if (match == null) continue;
    tables[match.group(1)!.toLowerCase()] = _columnsOf(
      statement.substring(match.end, statement.lastIndexOf(')')),
    );
  }
  return tables;
}

/// The column names in the body of a ``CREATE TABLE``.
Set<String> _columnsOf(String body) {
  // Split on the commas that separate *definitions*: the ones inside
  // `REFERENCES publishers (id)` or a composite primary key must not count.
  final definitions = <String>[];
  final current = StringBuffer();
  var depth = 0;
  for (final rune in body.runes) {
    final char = String.fromCharCode(rune);
    if (char == '(') depth++;
    if (char == ')') depth--;
    if (char == ',' && depth == 0) {
      definitions.add(current.toString());
      current.clear();
      continue;
    }
    current.write(char);
  }
  definitions.add(current.toString());

  final columns = <String>{};
  for (final definition in definitions) {
    final text = definition.trim();
    if (text.isEmpty) continue;
    final first = text.split(RegExp(r'\s+')).first.toLowerCase();
    // Table-level constraints start with a keyword, not a column name.
    if (const {'primary', 'unique', 'foreign', 'check', 'constraint'}
        .contains(first)) {
      continue;
    }
    columns.add(first);
  }
  return columns;
}

void main() {
  final fixture =
      json.decode(
            File('test/fixtures/server_schema.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final server = <String, Set<String>>{
    for (final entry in (fixture['tables'] as Map<String, dynamic>).entries)
      entry.key: {for (final column in entry.value as List) '$column'},
  };
  final phone = _tablesFromDdl();

  test('the fixture really is the server schema', () {
    // Otherwise a truncated file would make every test below quietly pointless.
    expect(server.keys, containsAll(['users', 'tokens', 'books', 'loans']));
    expect(server['books'], containsAll(['published_year', 'saga_number']));
    expect(server['books'], hasLength(greaterThan(10)));
  });

  test('the phone has every server table except the accounts', () {
    expect(phone.keys.toSet(), server.keys.toSet().difference(_accounts));
  });

  group('column for column', () {
    for (final entry in server.entries) {
      if (_accounts.contains(entry.key)) continue;
      test(entry.key, () {
        final columns = phone[entry.key];
        expect(columns, isNotNull, reason: '${entry.key} is missing entirely');
        expect(
          columns!.difference(entry.value),
          isEmpty,
          reason: '${entry.key} has columns the server does not',
        );
        expect(
          entry.value.difference(columns),
          isEmpty,
          reason: '${entry.key} is missing server columns',
        );
      });
    }
  });
}
