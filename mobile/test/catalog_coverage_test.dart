/// Guards against an untranslated label slipping into a screen.
///
/// English is the source language, so every string the app looks up is a key in
/// ``app/locales/es-419.json``. This walks the source, finds every
/// ``.tr``/``.tf``/``.tn`` call, and fails if the catalogue is missing one.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _call = RegExp(r'\.(tr|tf|tn)\(');

/// Read the single-quoted literal starting at [index]; returns it and the
/// index just past its closing quote.
(String, int) _readLiteral(String text, int index) {
  assert(text[index] == "'");
  final buffer = StringBuffer();
  var i = index + 1;
  while (i < text.length) {
    final char = text[i];
    if (char == r'\') {
      buffer.write(text.substring(i, i + 2));
      i += 2;
      continue;
    }
    if (char == "'") return (buffer.toString(), i + 1);
    buffer.write(char);
    i++;
  }
  throw StateError('unterminated literal at $index');
}

/// Read every single-quoted literal between [start] and its matching ``)``.
///
/// Used for the handful of calls whose first argument is an expression rather
/// than a literal (``tr(isEdit ? 'A' : 'B')``).
List<String> _literalsInGroup(String text, int start) {
  final literals = <String>[];
  var depth = 0;
  var i = start;
  while (i < text.length) {
    final char = text[i];
    if (char == "'") {
      final (literal, next) = _readLiteral(text, i);
      literals.add(literal);
      i = next;
      continue;
    }
    if (char == '(') depth++;
    if (char == ')') {
      if (depth == 0) break;
      depth--;
    }
    i++;
  }
  return literals;
}

/// Every catalogue key one Dart file looks up.
Set<String> _keysIn(String text) {
  final keys = <String>{};
  for (final call in _call.allMatches(text)) {
    var i = call.end;
    while (i < text.length && ' \t\r\n'.contains(text[i])) {
      i++;
    }
    if (i >= text.length) continue;
    if (text[i] != "'") {
      // An expression: a ternary with two labels, or a variable holding one.
      keys.addAll(_literalsInGroup(text, i));
      continue;
    }
    // One or more adjacent literals concatenate into a single source string.
    final parts = <String>[];
    while (i < text.length && text[i] == "'") {
      final (literal, next) = _readLiteral(text, i);
      parts.add(literal);
      i = next;
      while (i < text.length && ' \t\r\n'.contains(text[i])) {
        i++;
      }
    }
    if (parts.isNotEmpty) keys.add(parts.join());
  }
  return keys;
}

String _unescape(String value) => value
    .replaceAll(r"\'", "'")
    .replaceAll(r'\"', '"')
    .replaceAll(r'\\', r'\');

void main() {
  test('every string the app shows has a Spanish translation', () {
    final catalog =
        json.decode(File('../app/locales/es-419.json').readAsStringSync())
            as Map<String, dynamic>;

    final missing = <String, List<String>>{};
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    for (final file in files) {
      final text = file.readAsStringSync();
      for (final raw in _keysIn(text)) {
        final key = _unescape(raw);
        if (key.trim().isEmpty) continue;
        if (!catalog.containsKey(key)) {
          missing.putIfAbsent(key, () => []).add(file.path);
        }
      }
    }

    expect(
      missing,
      isEmpty,
      reason:
          'Untranslated strings (add them to app/locales/es-419.json):\n'
          '${missing.entries.map((e) => '  "${e.key}"  (${e.value.join(', ')})').join('\n')}',
    );
  });
}
