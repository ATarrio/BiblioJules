/// Parsing and importing Goodreads / StoryGraph CSV exports.
///
/// The server has a Python importer; this is the same idea on the phone. It
/// deliberately lives in the client so one import path works in local mode
/// (SQLite on the device) and server mode (the normal book/want-list API).
library;

import 'dart:math';

import 'api_exception.dart';
import 'book_fields.dart';
import 'library_repo.dart';
import 'models/models.dart';

const int kMaxCsvBytes = 20 * 1024 * 1024;
const int kMaxImportRows = 5000;

class ImportRow {
  ImportRow(this.data, {this.selected = true});

  final Map<String, dynamic> data;
  bool selected;

  String get title => '${data['title'] ?? ''}'.trim();
  String get authors {
    final value = data['authors'];
    if (value is List) return value.map((name) => '$name').join(', ');
    return '${value ?? ''}'.trim();
  }

  String? get isbn {
    final value = '${data['isbn'] ?? ''}'.trim();
    return value.isEmpty ? null : value;
  }
}

class ImportOutcome {
  ImportOutcome({
    this.imported = 0,
    this.skipped = 0,
    this.addedToWantList = 0,
    List<String>? errors,
  }) : errors = errors ?? [];

  final int imported;
  final int skipped;
  final int addedToWantList;
  final List<String> errors;
}

/// Parse CSV text into rows with the same standardised keys as the server.
List<ImportRow> parseImportCsv(String text) {
  var source = text;
  if (source.startsWith('\uFEFF')) source = source.substring(1);
  final delimiter = _detectDelimiter(source);
  final table = _parseCsv(source, delimiter);
  if (table.isEmpty) return const [];

  final headers = <String>[];
  for (final raw in table.first) {
    headers.add(
      raw
          .toLowerCase()
          .trim()
          .replaceAll(' ', '_')
          .replaceAll('(', '')
          .replaceAll(')', ''),
    );
  }

  final rows = <ImportRow>[];
  for (final cells in table.skip(1)) {
    if (cells.every((cell) => cell.trim().isEmpty)) continue;
    final row = <String, dynamic>{};
    for (
      var index = 0;
      index < headers.length && index < cells.length;
      index++
    ) {
      final key = headers[index];
      if (key.isEmpty) continue;
      final value = cells[index];
      if (value.isNotEmpty) row[key] = value;
    }
    if (row.isEmpty) continue;

    for (final alias in const [
      'author',
      'author_s',
      'author_name',
      'authors',
    ]) {
      final value = '${row[alias] ?? ''}'.trim();
      if (value.isNotEmpty) {
        row['authors'] = value;
        break;
      }
    }
    for (final alias in const ['title', 'book_title', 'name']) {
      final value = '${row[alias] ?? ''}'.trim();
      if (value.isNotEmpty) {
        row['title'] = value;
        break;
      }
    }
    for (final alias in const ['isbn', 'isbn_10', 'isbn_13', 'isbn13', 'isbn/uid', 'uid']) {
      final value = '${row[alias] ?? ''}'.trim();
      if (value.isNotEmpty) {
        row['isbn'] = normalizeIsbn(value);
        break;
      }
    }
    for (final alias in const [
      'publication_year',
      'published_year',
      'year_published',
      'year',
      'publish_year',
    ]) {
      final value = '${row[alias] ?? ''}'.trim();
      if (value.isNotEmpty) {
        row['published_year'] = value;
        break;
      }
    }
    for (final alias in const ['rating', 'my_rating', 'rating_2', 'rating_5']) {
      final raw = '${row[alias] ?? ''}'.trim().replaceAll(',', '.');
      if (raw.isEmpty) continue;
      final value = double.tryParse(raw);
      if (value != null && value >= 0 && value <= 5) row['score'] = value;
      break;
    }
    for (final alias in const [
      'number_of_pages',
      'pages',
      'page_count',
      'pages_',
    ]) {
      final raw = '${row[alias] ?? ''}'.trim();
      if (raw.isEmpty) continue;
      final value = int.tryParse(raw);
      if (value != null) row['page_count'] = value;
      break;
    }

    final statusRaw = '${row['read_status'] ?? row['exclusive_shelf'] ?? ''}'
        .trim()
        .toLowerCase();
    final statusKey = statusRaw.replaceAll('-', '_').replaceAll(' ', '_');
    const statusMap = <String, String>{
      'read': 'read',
      'to_read': 'to_read',
      'want_to_read': 'to_read',
      'currently_reading': 'currently_reading',
      'reading': 'currently_reading',
      'unread': 'unread',
      'not_read': 'unread',
      'dnf': 'dnf',
      'did_not_finish': 'dnf',
    };
    final mapped = statusMap[statusKey];
    if (mapped != null) {
      row['read_status'] = mapped;
    } else {
      // An unknown shelf must not reach the library as a status.
      row.remove('read_status');
    }

    for (final alias in const ['date_added', 'date_added_', 'date_added_2']) {
      final value = '${row[alias] ?? ''}'.trim();
      if (value.isNotEmpty) {
        row['date_added'] = value;
        break;
      }
    }
    for (final field in const [
      'description',
      'cover_url',
      'publisher',
      'language',
    ]) {
      final value = '${row[field] ?? ''}'.trim();
      if (value.isNotEmpty) row[field] = value;
    }
    rows.add(ImportRow(row));
  }
  return rows;
}

String _detectDelimiter(String text) {
  final firstLine = text.split(RegExp(r'\r?\n')).first;
  var commas = 0;
  var semicolons = 0;
  var quoted = false;
  for (final code in firstLine.codeUnits) {
    if (code == 0x22) {
      quoted = !quoted;
    } else if (!quoted && code == 0x2C) {
      commas++;
    } else if (!quoted && code == 0x3B) {
      semicolons++;
    }
  }
  return semicolons > commas ? ';' : ',';
}

List<List<String>> _parseCsv(String text, String delimiter) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var index = 0;

  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    endField();
    if (row.any((cell) => cell.isNotEmpty)) rows.add(row);
    row = <String>[];
  }

  while (index < text.length) {
    final char = text[index];
    if (quoted) {
      if (char == '"') {
        if (index + 1 < text.length && text[index + 1] == '"') {
          field.write('"');
          index += 2;
          continue;
        }
        quoted = false;
      } else {
        field.write(char);
      }
      index++;
      continue;
    }
    if (char == '"') {
      quoted = true;
    } else if (char == delimiter) {
      endField();
    } else if (char == '\r' || char == '\n') {
      if (char == '\r' && index + 1 < text.length && text[index + 1] == '\n') {
        index++;
      }
      endRow();
    } else {
      field.write(char);
    }
    index++;
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

/// A new id for a hand-added want-to-read entry.
String newWantId() {
  final random = Random.secure();
  final suffix = List.generate(
    8,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return 'want-$suffix';
}

/// Create books / want-list entries from [rows], reporting progress.
Future<ImportOutcome> importRows(
  LibraryRepo repo,
  List<ImportRow> rows, {
  void Function(int done, int total)? onProgress,
}) async {
  var imported = 0;
  var skipped = 0;
  var addedToWantList = 0;
  final errors = <String>[];
  final wantTitles = <String>{
    for (final entry in await repo.wantList()) entry.title.trim().toLowerCase(),
  };
  final selected = rows.where((row) => row.selected).toList();

  for (var index = 0; index < selected.length; index++) {
    final row = selected[index];
    var title = row.title;
    var authors = row.authors;
    final isbn = row.isbn;
    try {
      // Fill what the export left blank, exactly like the server importer.
      // An offline lookup must not abort the row: the CSV may still carry
      // enough to import it.
      if (isbn != null && (title.isEmpty || authors.isEmpty)) {
        try {
          final lookup = await repo.lookupIsbn(isbn);
          if (lookup != null) {
            if (title.isEmpty) title = lookup.title;
            if (authors.isEmpty) authors = lookup.authors.join(', ');
            row.data['publisher'] ??= lookup.publisher;
            row.data['published_year'] ??= lookup.publishedDate;
            row.data['description'] ??= lookup.description;
            row.data['cover_url'] ??= lookup.coverUrl;
            row.data['page_count'] ??= lookup.pageCount;
            row.data['language'] ??= lookup.language;
          }
        } on Object {
          // Keep the CSV metadata and continue with the import.
        }
      }
      if (title.isEmpty) title = 'Untitled';
      if (isbn == null || isbn.isEmpty) {
        final key = title.toLowerCase();
        if (wantTitles.contains(key)) {
          skipped++;
        } else {
          final publisher = '${row.data['publisher'] ?? ''}'.trim();
          await repo.addWant(
            WantEntry(
              id: newWantId(),
              title: title,
              isbn: isbn,
              authors: authors,
              publisher: publisher.isEmpty ? null : publisher,
              addedAt: DateTime.now().toUtc().toIso8601String(),
            ),
          );
          wantTitles.add(key);
          addedToWantList++;
        }
      } else if (await repo.findByIsbn(isbn) != null) {
        skipped++;
      } else {
        await repo.createBook(<String, dynamic>{
          'isbn': isbn,
          'title': title,
          'authors': authors,
          'publisher': row.data['publisher'],
          'published_date': '${row.data['published_year'] ?? ''}'.trim().isEmpty
              ? null
              : '${row.data['published_year']}',
          'page_count': row.data['page_count'],
          'language': row.data['language'],
          'cover_url': row.data['cover_url'],
          'description': row.data['description'],
          'score': row.data['score'],
          'read_status': row.data['read_status'],
          'source': 'csv_import',
        });
        imported++;
      }
    } on ApiAuthException {
      // The session is gone: let the caller sign out instead of reporting one
      // failed row per record.
      rethrow;
    } on Object catch (error) {
      errors.add('$title: $error');
    }
    onProgress?.call(index + 1, selected.length);
  }
  return ImportOutcome(
    imported: imported,
    skipped: skipped,
    addedToWantList: addedToWantList,
    errors: errors,
  );
}
