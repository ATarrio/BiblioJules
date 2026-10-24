/// Sharing one library between devices, without a server.
///
/// A direct port of ``app/services/sync.py``: the phone keeps its own SQLite
/// file and the shared folder (a Google Drive folder, a Syncthing folder, a USB
/// stick — anything that copies a file) carries a *snapshot*. [LibrarySync]
/// reads that snapshot, merges it into the local library, then writes the merged
/// result back. The shared file is never opened live, so no amount of cloud
/// latency can corrupt a library.
///
/// A snapshot is a normal BiblioJules database — ``VACUUM INTO`` of the live one
/// — minus accounts (a phone has none) plus one extra table, ``sync_meta``: a
/// small key/value header with the format, a fresh ``snapshot_id``, a generation
/// counter and the exporting device's name.
///
/// Merging is last-write-wins per row, keyed by ``sync_id``. Some tables also
/// have a natural key, so the *first* sync can marry rows that were created
/// independently on two devices: statuses by ``slug`` (then name), authors and
/// publishers by name, books by ISBN. Locations only match by ``sync_id`` — two
/// shelves may honestly share a name. Deletions travel as tombstones; the newer
/// of a delete and an edit wins, so a late edit resurrects a deleted row.
///
/// This file mirrors the Python statement for statement, and
/// ``test/sync_test.dart`` runs the same scenario against both sides to keep
/// them in step.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'converters.dart';
import 'local_repo.dart';
import 'schema.dart';
import 'sync_ids.dart';

/// Bumped if the layout of a snapshot (not the library schema) ever changes.
const int kSyncFormat = 1;

/// One fixed name in every shared folder, whichever client wrote it.
const String kSnapshotName = 'bibliojules-library.sqlite';

/// Where the per-device identity and the last seen snapshot are remembered.
const String kSyncStateName = 'sync_state.json';

/// Local copies taken just before a merge, so a bad merge is never final.
const String kBackupFolderName = 'backups';
const int kKeepBackups = 10;

/// How many times a sync re-reads a folder that changed under it.
const int kMaxMergeAttempts = 3;

/// The channel ``MainActivity.kt`` listens on (shared with the file picker).
const String kFilesChannel = 'bibliojules/files';

const List<String> _statusFields = <String>[
  'name',
  'slug',
  'color',
  'icon',
  'description',
  'sort_order',
  'is_system',
  'is_default',
];

const List<String> _locationFields = <String>['name', 'kind', 'description'];

const List<String> _bookFields = <String>[
  'isbn',
  'title',
  'subtitle',
  'published_date',
  'published_year',
  'description',
  'page_count',
  'language',
  'cover_url',
  'cover_type',
  'read_status',
  'score',
  'saga',
  'saga_number',
  'source',
  'notes',
];

const List<String> _loanFields = <String>[
  'borrower_name',
  'borrower_contact',
  'lent_at',
  'due_at',
  'returned_at',
  'notes',
];

/// What a user should read when a sync cannot run.
class SyncException implements Exception {
  SyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The header of a snapshot: everything a merge needs to know before opening
/// the tables.
class SyncSnapshotMeta {
  SyncSnapshotMeta({
    required this.format,
    required this.schemaVersion,
    required this.snapshotId,
    required this.generation,
    required this.exportedAt,
    required this.deviceId,
    required this.deviceName,
    required this.basedOn,
    required this.rowCounts,
  });

  final int format;
  final int schemaVersion;
  final String snapshotId;
  final int generation;
  final String exportedAt;
  final String deviceId;
  final String deviceName;
  final String? basedOn;
  final Map<String, int> rowCounts;
}

/// What changed locally because of the snapshot, in user-facing terms.
class SyncMergeSummary {
  String sourceDevice = '';
  int sourceGeneration = 0;
  final Map<String, int> added = <String, int>{};
  final Map<String, int> updated = <String, int>{};
  final Map<String, int> deleted = <String, int>{};
  final List<String> conflicts = <String>[];

  void bump(Map<String, int> bucket, String table, [int count = 1]) {
    bucket[table] = (bucket[table] ?? 0) + count;
  }

  int get changes =>
      _sum(added) + _sum(updated) + _sum(deleted);

  static int _sum(Map<String, int> bucket) =>
      bucket.values.fold(0, (total, value) => total + value);

  Map<String, Object?> toJson() => <String, Object?>{
    'source_device': sourceDevice,
    'source_generation': sourceGeneration,
    'added': added,
    'updated': updated,
    'deleted': deleted,
    'conflicts': conflicts,
    'changes': changes,
  };
}

/// Everything one [LibrarySync.run] did.
class SyncResult {
  SyncResult({
    required this.snapshot,
    this.merge,
    this.pushed = false,
    this.mergedSnapshot = false,
  });

  final SyncSnapshotMeta snapshot;
  final SyncMergeSummary? merge;
  final bool pushed;
  final bool mergedSnapshot;

  Map<String, Object?> toJson() => <String, Object?>{
    'snapshot': <String, Object?>{
      'snapshot_id': snapshot.snapshotId,
      'generation': snapshot.generation,
      'device_name': snapshot.deviceName,
      'exported_at': snapshot.exportedAt,
    },
    'merge': merge?.toJson(),
    'pushed': pushed,
    'merged_snapshot': mergedSnapshot,
  };
}

/// The little bit of per-device bookkeeping a sync needs.
class SyncState {
  SyncState({
    this.deviceId = '',
    this.deviceName = '',
    this.lastSnapshotId,
    this.lastChangeAt,
    this.lastSyncAt,
    this.lastResult,
  });

  String deviceId;
  String deviceName;
  String? lastSnapshotId;
  String? lastChangeAt;
  String? lastSyncAt;
  Map<String, Object?>? lastResult;

  static Future<SyncState> load(File file) async {
    if (!file.existsSync()) return SyncState();
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return SyncState();
      return SyncState(
        deviceId: '${data['device_id'] ?? ''}',
        deviceName: '${data['device_name'] ?? ''}',
        lastSnapshotId: data['last_snapshot_id'] as String?,
        lastChangeAt: data['last_change_at'] as String?,
        lastSyncAt: data['last_sync_at'] as String?,
        lastResult: (data['last_result'] as Map?)?.cast<String, Object?>(),
      );
    } on Object {
      return SyncState();
    }
  }

  Future<void> save(File file) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'device_id': deviceId,
        'device_name': deviceName,
        'last_snapshot_id': lastSnapshotId,
        'last_change_at': lastChangeAt,
        'last_sync_at': lastSyncAt,
        'last_result': lastResult,
      }),
      flush: true,
    );
    if (file.existsSync()) await file.delete();
    await tmp.rename(file.path);
  }
}

/// A name for this device, shown in the other clients' logs and summaries.
String defaultDeviceName() {
  final host = Platform.localHostname.trim();
  if (host.isNotEmpty && host != 'localhost') return host;
  if (Platform.isAndroid) return 'Android device';
  return host.isEmpty ? 'This device' : host;
}

/// Seconds-free comparison: microseconds since the epoch, UTC.
///
/// Timestamps are compared as instants, never as strings: SQLite stores
/// ``YYYY-MM-DD HH:MM:SS.ffffff``, a server may write an ISO ``T``, and a phone
/// in another timezone must still order them the same way.
int stampMicros(Object? value) {
  if (value == null) return 0;
  var text = value.toString().trim();
  if (text.isEmpty) return 0;
  if (text.endsWith('Z')) {
    text = '${text.substring(0, text.length - 1)}+00:00';
  }
  final hasZone = text.endsWith('Z') ||
      RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(text);
  final parsed = DateTime.tryParse(
    '${text.replaceFirst(' ', 'T')}${hasZone ? '' : 'Z'}',
  );
  if (parsed == null) return 0;
  final micros = parsed.microsecondsSinceEpoch;
  // A device whose clock is years ahead would win every conflict forever.
  // Clamp far-future stamps to "now" so a later edit with a sane clock can win.
  final now = DateTime.now().microsecondsSinceEpoch;
  return micros > now + const Duration(seconds: 300).inMicroseconds
      ? now
      : micros;
}

// --------------------------------------------------------------------------- //
// Snapshot files
// --------------------------------------------------------------------------- //

Future<Database> _openReadOnly(File file) => openDatabase(
  file.path,
  readOnly: true,
  singleInstance: false,
);

Future<Database> _openLive(String path, {bool readOnly = false}) => openDatabase(
  path,
  readOnly: readOnly,
  singleInstance: false,
  onConfigure: (db) async {
    await db.execute('PRAGMA foreign_keys = ON');
    // The repo keeps its own connection open; wait for it instead of failing
    // the whole sync with "database is locked" when a screen is saving.
    await db.rawQuery('PRAGMA busy_timeout = 15000');
  },
);

/// Open just the header of a snapshot, refusing anything unusable.
Future<SyncSnapshotMeta> readSnapshotMeta(File file) async {
  if (!file.existsSync()) {
    throw SyncException('The shared library file is missing.');
  }
  final Database db;
  try {
    db = await _openReadOnly(file);
  } on DatabaseException {
    throw SyncException('The shared library file is not a readable database.');
  }
  try {
    final List<Map<String, Object?>> check;
    try {
      check = await db.rawQuery('PRAGMA integrity_check');
    } on DatabaseException {
      throw SyncException(
        'The shared library file is damaged or is not a SQLite database.',
      );
    }
    if (check.isEmpty || '${check.first.values.first}' != 'ok') {
      throw SyncException(
        'The shared library file is damaged or was only partly copied. '
        'Wait for the folder to finish syncing and try again.',
      );
    }
    final tables = <String>{
      for (final row in await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ))
        '${row['name']}'.toLowerCase(),
    };
    final missing = kRequiredTables.where((t) => !tables.contains(t)).toList();
    if (missing.isNotEmpty) {
      throw SyncException('The shared file is not a BiblioJules library.');
    }
    if (!tables.contains('sync_meta')) {
      throw SyncException(
        'This file is a plain library export, not a sync snapshot. Choose a '
        'shared folder and sync once to publish a snapshot.',
      );
    }
    final raw = <String, String>{
      for (final row in await db.rawQuery('SELECT key, value FROM sync_meta'))
        '${row['key']}': '${row['value']}',
    };
    final counts =
        (jsonDecode(raw['row_counts'] ?? '{}') as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final meta = SyncSnapshotMeta(
      format: int.tryParse(raw['format'] ?? '') ?? 0,
      schemaVersion: int.tryParse(raw['schema_version'] ?? '') ?? 0,
      snapshotId: raw['snapshot_id'] ?? '',
      generation: int.tryParse(raw['generation'] ?? '') ?? 1,
      exportedAt: raw['exported_at'] ?? '',
      deviceId: raw['device_id'] ?? '',
      deviceName: raw['device_name'] ?? '',
      basedOn: (raw['based_on'] ?? '').isEmpty ? null : raw['based_on'],
      rowCounts: <String, int>{
        for (final entry in counts.entries)
          entry.key: int.tryParse('${entry.value}') ?? 0,
      },
    );
    if (meta.snapshotId.isEmpty) {
      throw SyncException('The snapshot header is incomplete or damaged.');
    }
    if (meta.format != kSyncFormat) {
      throw SyncException(
        'This snapshot was written by a different version of BiblioJules. '
        'Update every device to the same version, then try again.',
      );
    }
    return meta;
  } finally {
    await db.close();
  }
}

// --------------------------------------------------------------------------- //
// Merge helpers
// --------------------------------------------------------------------------- //

Future<List<Map<String, Object?>>> _rows(
  DatabaseExecutor db,
  String table,
) async => <Map<String, Object?>>[
  // sqflite hands out immutable rows; the merge edits the copies it keeps in
  // memory (adopting a sync id, adopting the winner's fields), so take a
  // writable copy of each row.
  for (final row in await db.rawQuery('SELECT * FROM "$table"'))
    Map<String, Object?>.from(row),
];

Map<String, Map<String, Object?>> _by(
  List<Map<String, Object?>> rows,
  String key,
) => <String, Map<String, Object?>>{
  for (final row in rows)
    if (row[key] != null) '${row[key]}': row,
};

Future<int> _insert(
  DatabaseExecutor db,
  String table,
  Map<String, Object?> values,
) {
  final data = Map<String, Object?>.from(values)..remove('id');
  return db.insert(table, data);
}

Future<void> _update(
  DatabaseExecutor db,
  String table,
  int id,
  Map<String, Object?> values,
) async {
  if (values.isEmpty) return;
  await db.update(table, values, where: 'id = ?', whereArgs: <Object?>[id]);
}

/// Last write wins; identical instants are settled by ``sync_id``.
bool _newer(Map<String, Object?> remote, Map<String, Object?> local) {
  final left = stampMicros(remote['updated_at']);
  final right = stampMicros(local['updated_at']);
  if (left != right) return left > right;
  return '${remote['sync_id'] ?? ''}'.compareTo('${local['sync_id'] ?? ''}') > 0;
}

/// Like [_newer], but a returned loan wins an exact timestamp tie.
bool _loanNewer(Map<String, Object?> remote, Map<String, Object?> local) {
  final left = stampMicros(remote['updated_at']);
  final right = stampMicros(local['updated_at']);
  if (left != right) return left > right;
  final remoteReturned = remote['returned_at'] != null;
  final localReturned = local['returned_at'] != null;
  if (remoteReturned != localReturned) return remoteReturned;
  return '${remote['sync_id'] ?? ''}'.compareTo('${local['sync_id'] ?? ''}') > 0;
}

/// Both sides changed this row since our last successful sync.
bool _conflict(String? since, Map<String, Object?> remote, Map<String, Object?> local) {
  if (since == null || since.isEmpty) return false;
  final boundary = stampMicros(since);
  return stampMicros(local['updated_at']) > boundary &&
      stampMicros(remote['updated_at']) > boundary;
}

/// True when this device deleted the row and the incoming copy is older.
///
/// A newer incoming copy wins (the user edited it elsewhere) and the local
/// tombstone is dropped, which is how an edit resurrects a deleted row.
Future<bool> _blockedByLocalTombstone(
  DatabaseExecutor db,
  String table,
  String syncId,
  Object? remoteUpdated,
) async {
  final rows = await db.query(
    'sync_tombstones',
    where: 'table_name = ? AND sync_id = ?',
    whereArgs: <Object?>[table, syncId],
    limit: 1,
  );
  if (rows.isEmpty) return false;
  if (stampMicros(rows.first['deleted_at']) >= stampMicros(remoteUpdated)) {
    return true;
  }
  await db.delete(
    'sync_tombstones',
    where: 'table_name = ? AND sync_id = ?',
    whereArgs: <Object?>[table, syncId],
  );
  return false;
}

/// Give a locally-created row the incoming identity of its natural twin.
///
/// Without this each device would keep believing the other lacks the row, and
/// every sync would rewrite the snapshot.
Future<void> _adoptSyncId(
  DatabaseExecutor db,
  String table,
  Map<String, Object?> local,
  String syncId,
  Map<String, Map<String, Object?>> bySync,
) async {
  final previous = local['sync_id'] as String?;
  await db.update(
    table,
    <String, Object?>{'sync_id': syncId},
    where: 'id = ?',
    whereArgs: <Object?>[local['id']],
  );
  if (previous != null) bySync.remove(previous);
  local['sync_id'] = syncId;
}

/// Replace a book's author links with the winning side's list.
Future<void> _replaceAuthors(
  DatabaseExecutor db,
  int bookId,
  List<String> authorSyncIds,
  Map<String, int> authorMap,
) async {
  await db.delete('book_authors', where: 'book_id = ?', whereArgs: <Object?>[bookId]);
  final seen = <int>{};
  for (final syncId in authorSyncIds) {
    final authorId = authorMap[syncId];
    if (authorId == null || !seen.add(authorId)) continue;
    await db.insert('book_authors', <String, Object?>{
      'book_id': bookId,
      'author_id': authorId,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}

int _locationDepth(
  Map<int, Map<String, Object?>> rowsById,
  Map<String, Object?> row,
) {
  var depth = 0;
  final seen = <int>{};
  var parent = row['parent_id'] as int?;
  while (parent != null && rowsById.containsKey(parent) && seen.add(parent)) {
    depth++;
    parent = rowsById[parent]!['parent_id'] as int?;
  }
  return depth;
}

/// Parents before children, so a shelf can be inserted in one pass.
List<Map<String, Object?>> _sortLocations(List<Map<String, Object?>> rows) {
  final rowsById = <int, Map<String, Object?>>{
    for (final row in rows) row['id']! as int: row,
  };
  final sorted = List<Map<String, Object?>>.from(rows);
  sorted.sort((a, b) {
    final byDepth = _locationDepth(rowsById, a).compareTo(
      _locationDepth(rowsById, b),
    );
    if (byDepth != 0) return byDepth;
    return (a['id']! as int).compareTo(b['id']! as int);
  });
  return sorted;
}

// --------------------------------------------------------------------------- //
// Applying a snapshot
// --------------------------------------------------------------------------- //

/// Keep a remote deletion locally so it keeps travelling to other devices.
///
/// Applying a deletion used to drop the marker, so an offline device could
/// push the row back on the next sync.
Future<void> _rememberRemoteTombstone(
  DatabaseExecutor db,
  String table,
  Map<String, Object?> tombstone,
) async {
  final syncId = '${tombstone['sync_id']}';
  final deletedAt = tombstone['deleted_at'];
  final existing = await db.query(
    'sync_tombstones',
    columns: <String>['deleted_at'],
    where: 'table_name = ? AND sync_id = ?',
    whereArgs: <Object?>[table, syncId],
    limit: 1,
  );
  if (existing.isEmpty) {
    await db.insert('sync_tombstones', <String, Object?>{
      'table_name': table,
      'sync_id': syncId,
      'deleted_at': deletedAt,
    });
  } else if (stampMicros(deletedAt) > stampMicros(existing.first['deleted_at'])) {
    await db.update(
      'sync_tombstones',
      <String, Object?>{'deleted_at': deletedAt},
      where: 'table_name = ? AND sync_id = ?',
      whereArgs: <Object?>[table, syncId],
    );
  }
}

/// Deletions made on the other device, applied only where they still win.
Future<void> _applyRemoteTombstones(
  DatabaseExecutor db,
  DatabaseExecutor remote,
  SyncMergeSummary summary,
) async {
  final tombstones = await _rows(remote, 'sync_tombstones');
  if (tombstones.isEmpty) return;

  final byTable = <String, List<Map<String, Object?>>>{};
  for (final row in tombstones) {
    (byTable['${row['table_name']}'] ??= <Map<String, Object?>>[]).add(row);
  }

  Future<Map<String, Object?>?> localBySyncId(String table, String syncId) async {
    final rows = await db.query(
      table,
      where: 'sync_id = ?',
      whereArgs: <Object?>[syncId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  for (final tombstone in byTable['statuses'] ?? const <Map<String, Object?>>[]) {
    final local = await localBySyncId('statuses', '${tombstone['sync_id']}');
    if (local == null ||
        stampMicros(tombstone['deleted_at']) < stampMicros(local['updated_at'])) {
      continue;
    }
    final fallback = await db.query(
      'statuses',
      where: "slug = 'available'",
      limit: 1,
    );
    await db.update(
      'books',
      <String, Object?>{'status_id': fallback.isEmpty ? null : fallback.first['id']},
      where: 'status_id = ?',
      whereArgs: <Object?>[local['id']],
    );
    await db.delete('statuses', where: 'id = ?', whereArgs: <Object?>[local['id']]);
    await _rememberRemoteTombstone(db, 'statuses', tombstone);
    summary.bump(summary.deleted, 'statuses');
  }

  for (final tombstone in byTable['books'] ?? const <Map<String, Object?>>[]) {
    final local = await localBySyncId('books', '${tombstone['sync_id']}');
    if (local == null ||
        stampMicros(tombstone['deleted_at']) < stampMicros(local['updated_at'])) {
      continue;
    }
    await db.delete('books', where: 'id = ?', whereArgs: <Object?>[local['id']]);
    await _rememberRemoteTombstone(db, 'books', tombstone);
    summary.bump(summary.deleted, 'books');
  }

  final locations = byTable['locations'] ?? const <Map<String, Object?>>[];
  if (locations.isNotEmpty) {
    final localRows = await _rows(db, 'locations');
    final rowsById = <int, Map<String, Object?>>{
      for (final row in localRows) row['id']! as int: row,
    };
    final localBySync = _by(localRows, 'sync_id');
    int depthOf(Map<String, Object?> tombstone) {
      final local = localBySync['${tombstone['sync_id']}'];
      return local == null ? -1 : _locationDepth(rowsById, local);
    }

    final ordered = List<Map<String, Object?>>.from(locations)
      ..sort((a, b) => depthOf(b).compareTo(depthOf(a)));
    // Children first: deleting a parent cascades, so a child that survived on
    // this device has to be moved out of the way before its shelf goes.
    for (final tombstone in ordered) {
      final local = localBySync['${tombstone['sync_id']}'];
      if (local == null ||
          stampMicros(tombstone['deleted_at']) < stampMicros(local['updated_at'])) {
        continue;
      }
      await db.update(
        'locations',
        <String, Object?>{'parent_id': local['parent_id']},
        where: 'parent_id = ?',
        whereArgs: <Object?>[local['id']],
      );
      await db.delete('locations', where: 'id = ?', whereArgs: <Object?>[local['id']]);
      await _rememberRemoteTombstone(db, 'locations', tombstone);
      summary.bump(summary.deleted, 'locations');
    }
  }
}

/// Merge statuses by ``sync_id``, then by slug/name so the seeded rows unify.
Future<Map<String, int>> _mergeStatuses(
  DatabaseExecutor db,
  List<Map<String, Object?>> remoteRows,
  SyncMergeSummary summary,
  String? since,
) async {
  final localRows = await _rows(db, 'statuses');
  final bySync = _by(localRows, 'sync_id');
  final bySlug = <String, Map<String, Object?>>{
    for (final row in localRows)
      if (row['slug'] != null) '${row['slug']}': row,
  };
  final byName = <String, Map<String, Object?>>{
    for (final row in localRows)
      if (row['name'] != null) '${row['name']}'.toLowerCase(): row,
  };
  final mapping = <String, int>{};

  for (final remote in remoteRows) {
    final syncId = remote['sync_id'] as String?;
    if (syncId == null || syncId.isEmpty) continue;
    if (await _blockedByLocalTombstone(db, 'statuses', syncId, remote['updated_at'])) {
      continue;
    }
    var local = bySync[syncId] ?? bySlug['${remote['slug']}'];
    local ??= byName['${remote['name'] ?? ''}'.toLowerCase()];

    if (local == null) {
      final values = <String, Object?>{
        for (final field in _statusFields) field: remote[field],
        'sync_id': syncId,
        'created_at': remote['created_at'],
        'updated_at': remote['updated_at'],
      };
      final newId = await _insert(db, 'statuses', values);
      final inserted = <String, Object?>{...values, 'id': newId};
      bySync[syncId] = inserted;
      bySlug['${inserted['slug']}'] = inserted;
      byName['${inserted['name'] ?? ''}'.toLowerCase()] = inserted;
      mapping[syncId] = newId;
      summary.bump(summary.added, 'statuses');
      continue;
    }

    mapping[syncId] = local['id']! as int;
    if (local['sync_id'] != syncId) {
      await _adoptSyncId(db, 'statuses', local, syncId, bySync);
    }
    bySync[syncId] = local;
    if (_newer(remote, local)) {
      final values = <String, Object?>{
        for (final field in _statusFields)
          if (remote[field] != local[field]) field: remote[field],
        'updated_at': remote['updated_at'],
      };
      await _update(db, 'statuses', local['id']! as int, values);
      if (_conflict(since, remote, local)) {
        summary.conflicts.add(
          'status “${local['name']}”: kept the version from ${summary.sourceDevice}',
        );
      }
      local.addAll(values);
      summary.bump(summary.updated, 'statuses');
    }
  }
  return mapping;
}

/// Shelf trees merge by ``sync_id`` alone — two shelves may share a name.
Future<Map<String, int>> _mergeLocations(
  DatabaseExecutor db,
  List<Map<String, Object?>> remoteRows,
  SyncMergeSummary summary,
  String? since,
) async {
  final localRows = await _rows(db, 'locations');
  final bySync = _by(localRows, 'sync_id');
  final remoteSyncById = <int, String?>{
    for (final row in remoteRows) row['id']! as int: row['sync_id'] as String?,
  };
  final ordered = _sortLocations(remoteRows);
  final mapping = <String, int>{};
  final remoteWon = <String>{};

  for (final remote in ordered) {
    final syncId = remote['sync_id'] as String?;
    if (syncId == null || syncId.isEmpty) continue;
    if (await _blockedByLocalTombstone(db, 'locations', syncId, remote['updated_at'])) {
      continue;
    }
    final local = bySync[syncId];
    if (local == null) {
      final values = <String, Object?>{
        for (final field in _locationFields) field: remote[field],
        'parent_id': null,
        'sync_id': syncId,
        'created_at': remote['created_at'],
        'updated_at': remote['updated_at'],
      };
      final newId = await _insert(db, 'locations', values);
      final inserted = <String, Object?>{...values, 'id': newId};
      bySync[syncId] = inserted;
      mapping[syncId] = newId;
      remoteWon.add(syncId);
      summary.bump(summary.added, 'locations');
      continue;
    }

    mapping[syncId] = local['id']! as int;
    if (_newer(remote, local)) {
      final values = <String, Object?>{
        for (final field in _locationFields)
          if (remote[field] != local[field]) field: remote[field],
        'updated_at': remote['updated_at'],
      };
      await _update(db, 'locations', local['id']! as int, values);
      if (_conflict(since, remote, local)) {
        summary.conflicts.add(
          'shelf “${local['name']}”: kept the version from ${summary.sourceDevice}',
        );
      }
      local.addAll(values);
      summary.bump(summary.updated, 'locations');
      remoteWon.add(syncId);
    }
  }

  // Parents in a second pass: every row now has a local id to point at.
  for (final remote in ordered) {
    final syncId = remote['sync_id'] as String?;
    if (syncId == null || !mapping.containsKey(syncId) || !remoteWon.contains(syncId)) {
      continue;
    }
    final parentSync = remoteSyncById[remote['parent_id'] as int?];
    var parentId = parentSync == null ? null : mapping[parentSync];
    if (parentId == mapping[syncId]) parentId = null;
    await db.update(
      'locations',
      <String, Object?>{'parent_id': parentId},
      where: 'id = ?',
      whereArgs: <Object?>[mapping[syncId]],
    );
  }
  return mapping;
}

/// Authors and publishers, unified by name the first time they meet.
Future<Map<String, int>> _mergeNames(
  DatabaseExecutor db,
  String table,
  List<Map<String, Object?>> remoteRows,
  SyncMergeSummary summary,
  String? since,
) async {
  final localRows = await _rows(db, table);
  final bySync = _by(localRows, 'sync_id');
  final byName = <String, Map<String, Object?>>{
    for (final row in localRows)
      if (row['name'] != null) '${row['name']}'.toLowerCase(): row,
  };
  final mapping = <String, int>{};

  for (final remote in remoteRows) {
    final syncId = remote['sync_id'] as String?;
    if (syncId == null || syncId.isEmpty) continue;
    if (await _blockedByLocalTombstone(db, table, syncId, remote['updated_at'])) {
      continue;
    }
    final name = '${remote['name'] ?? ''}';
    var local = bySync[syncId];
    if (local == null && name.isNotEmpty) local = byName[name.toLowerCase()];

    if (local == null) {
      final values = <String, Object?>{
        'name': name,
        'sync_id': syncId,
        'updated_at': remote['updated_at'] ?? nowStamp(),
      };
      final newId = await _insert(db, table, values);
      final inserted = <String, Object?>{...values, 'id': newId};
      bySync[syncId] = inserted;
      byName[name.toLowerCase()] = inserted;
      mapping[syncId] = newId;
      summary.bump(summary.added, table);
      continue;
    }

    mapping[syncId] = local['id']! as int;
    if (local['sync_id'] != syncId) {
      await _adoptSyncId(db, table, local, syncId, bySync);
    }
    bySync[syncId] = local;
    if (_newer(remote, local)) {
      final values = <String, Object?>{'updated_at': remote['updated_at']};
      if (name.isNotEmpty && name.toLowerCase() != '${local['name']}'.toLowerCase()) {
        values['name'] = name;
      }
      await _update(db, table, local['id']! as int, values);
      local.addAll(values);
      summary.bump(summary.updated, table);
    }
  }
  return mapping;
}

Future<Map<String, int>> _mergeBooks(
  DatabaseExecutor db,
  DatabaseExecutor remote,
  List<Map<String, Object?>> remoteRows,
  Map<String, int> statusMap,
  Map<String, int> locationMap,
  Map<String, int> publisherMap,
  Map<String, int> authorMap,
  SyncMergeSummary summary,
  String? since,
) async {
  final publisherSync = <int, String?>{
    for (final row in await _rows(remote, 'publishers'))
      row['id']! as int: row['sync_id'] as String?,
  };
  final locationSync = <int, String?>{
    for (final row in await _rows(remote, 'locations'))
      row['id']! as int: row['sync_id'] as String?,
  };
  final statusSync = <int, String?>{
    for (final row in await _rows(remote, 'statuses'))
      row['id']! as int: row['sync_id'] as String?,
  };
  final authorSync = <int, String?>{
    for (final row in await _rows(remote, 'authors'))
      row['id']! as int: row['sync_id'] as String?,
  };
  final authorsByBook = <int, List<String>>{};
  for (final link in await _rows(remote, 'book_authors')) {
    final syncId = authorSync[link['author_id'] as int?];
    if (syncId != null) {
      (authorsByBook[link['book_id']! as int] ??= <String>[]).add(syncId);
    }
  }

  final localRows = await _rows(db, 'books');
  final bySync = _by(localRows, 'sync_id');
  final byIsbn = <String, Map<String, Object?>>{
    for (final row in localRows)
      if (row['isbn'] != null) '${row['isbn']}': row,
  };
  final mapping = <String, int>{};

  for (final remoteRow in remoteRows) {
    final syncId = remoteRow['sync_id'] as String?;
    if (syncId == null || syncId.isEmpty) continue;
    if (await _blockedByLocalTombstone(db, 'books', syncId, remoteRow['updated_at'])) {
      continue;
    }

    var matchedByIsbn = false;
    var local = bySync[syncId];
    final isbn = remoteRow['isbn'] as String?;
    if (local == null && isbn != null) {
      local = byIsbn[isbn];
      matchedByIsbn = local != null;
    }

    final values = <String, Object?>{
      for (final field in _bookFields) field: remoteRow[field],
      'publisher_id': publisherMap[publisherSync[remoteRow['publisher_id'] as int?]],
      'location_id': locationMap[locationSync[remoteRow['location_id'] as int?]],
      'status_id': statusMap[statusSync[remoteRow['status_id'] as int?]],
      'updated_at': remoteRow['updated_at'] ?? nowStamp(),
    };

    if (local == null) {
      values['sync_id'] = syncId;
      values['created_at'] = remoteRow['created_at'];
      int newId;
      try {
        newId = await _insert(db, 'books', values);
      } on DatabaseException catch (error) {
        // A duplicate ISBN must not abort the whole merge. Import the book
        // without the ISBN and report the clash instead.
        final isbnValue = values['isbn'];
        if (isbnValue != null && '$error'.contains('books.isbn')) {
          summary.conflicts.add(
            'book “${values['title']}”: ISBN $isbnValue is already used by another book',
          );
          values['isbn'] = null;
          newId = await _insert(db, 'books', values);
        } else {
          rethrow;
        }
      }
      final inserted = <String, Object?>{...values, 'id': newId};
      bySync[syncId] = inserted;
      if (inserted['isbn'] != null) byIsbn['${inserted['isbn']}'] = inserted;
      mapping[syncId] = newId;
      await _replaceAuthors(
        db,
        newId,
        authorsByBook[remoteRow['id']! as int] ?? const <String>[],
        authorMap,
      );
      summary.bump(summary.added, 'books');
      continue;
    }

    mapping[syncId] = local['id']! as int;
    if (local['sync_id'] != syncId) {
      await _adoptSyncId(db, 'books', local, syncId, bySync);
      if (matchedByIsbn) {
        summary.conflicts.add(
          'book “${local['title']}”: the same ISBN exists on both devices',
        );
      }
    }
    bySync[syncId] = local;
    if (_newer(remoteRow, local)) {
      final changed = <String, Object?>{
        for (final entry in values.entries)
          if (entry.value != local[entry.key]) entry.key: entry.value,
      };
      if (changed['isbn'] != null) {
        final owner = byIsbn['${changed['isbn']}'];
        if (owner != null && owner['id'] != local['id']) {
          // The incoming ISBN belongs to a different local book. Keep the old
          // ISBN instead of aborting the merge on the unique index.
          changed.remove('isbn');
          summary.conflicts.add(
            'book “${local['title']}”: ISBN ${values['isbn']} is already used by another book',
          );
        }
      }
      if (changed.isNotEmpty) {
        final previousIsbn = local['isbn'];
        await _update(db, 'books', local['id']! as int, changed);
        if (_conflict(since, remoteRow, local)) {
          summary.conflicts.add(
            'book “${local['title']}”: kept the version from ${summary.sourceDevice}',
          );
        }
        local.addAll(changed);
        // Keep the ISBN lookup in step with the row, otherwise a later remote
        // row carrying the old ISBN matches the wrong book.
        if (changed.containsKey('isbn')) {
          if (previousIsbn != null) byIsbn.remove('$previousIsbn');
          if (changed['isbn'] != null) byIsbn['${changed['isbn']}'] = local;
        }
        summary.bump(summary.updated, 'books');
      }
      // The author set travels with the winning book row.
      await _replaceAuthors(
        db,
        local['id']! as int,
        authorsByBook[remoteRow['id']! as int] ?? const <String>[],
        authorMap,
      );
    }
  }
  return mapping;
}

Future<void> _mergeLoans(
  DatabaseExecutor db,
  DatabaseExecutor remote,
  List<Map<String, Object?>> remoteRows,
  Map<String, int> bookMap,
  SyncMergeSummary summary,
) async {
  final bookSync = <int, String?>{
    for (final row in await _rows(remote, 'books'))
      row['id']! as int: row['sync_id'] as String?,
  };
  final localRows = await _rows(db, 'loans');
  final bySync = _by(localRows, 'sync_id');

  for (final remoteRow in remoteRows) {
    final syncId = remoteRow['sync_id'] as String?;
    if (syncId == null || syncId.isEmpty) continue;
    final remoteBookSync = bookSync[remoteRow['book_id'] as int?];
    final bookId = remoteBookSync == null ? null : bookMap[remoteBookSync];
    // The book was deleted on this device; the loan goes with it.
    if (bookId == null) continue;

    final values = <String, Object?>{
      for (final field in _loanFields) field: remoteRow[field],
      'book_id': bookId,
      'updated_at': remoteRow['updated_at'] ?? nowStamp(),
    };
    final local = bySync[syncId];
    if (local == null) {
      values['sync_id'] = syncId;
      values['created_at'] = remoteRow['created_at'];
      final newId = await _insert(db, 'loans', values);
      bySync[syncId] = <String, Object?>{...values, 'id': newId};
      summary.bump(summary.added, 'loans');
      continue;
    }
    if (_loanNewer(remoteRow, local)) {
      final changed = <String, Object?>{
        for (final entry in values.entries)
          if (entry.value != local[entry.key]) entry.key: entry.value,
      };
      if (changed.isNotEmpty) {
        await _update(db, 'loans', local['id']! as int, changed);
        local.addAll(changed);
        summary.bump(summary.updated, 'loans');
      }
    }
  }
}

Future<void> _mergeAll(
  DatabaseExecutor db,
  DatabaseExecutor remote,
  SyncMergeSummary summary,
  String? since,
) async {
  await _applyRemoteTombstones(db, remote, summary);
  final statusMap = await _mergeStatuses(
    db,
    await _rows(remote, 'statuses'),
    summary,
    since,
  );
  final locationMap = await _mergeLocations(
    db,
    await _rows(remote, 'locations'),
    summary,
    since,
  );
  final publisherMap = await _mergeNames(
    db,
    'publishers',
    await _rows(remote, 'publishers'),
    summary,
    since,
  );
  final authorMap = await _mergeNames(
    db,
    'authors',
    await _rows(remote, 'authors'),
    summary,
    since,
  );
  final bookMap = await _mergeBooks(
    db,
    remote,
    await _rows(remote, 'books'),
    statusMap,
    locationMap,
    publisherMap,
    authorMap,
    summary,
    since,
  );
  await _mergeLoans(db, remote, await _rows(remote, 'loans'), bookMap, summary);
  final pruned = await _pruneOrphans(db);
  // A name whose only book was deleted on the other device is inserted by the
  // merge and pruned again right here; do not report it as "added".
  for (final entry in pruned.entries) {
    for (final bucket in <Map<String, int>>[summary.added, summary.updated]) {
      final left = (bucket[entry.key] ?? 0) - entry.value;
      if (left > 0) {
        bucket[entry.key] = left;
      } else {
        bucket.remove(entry.key);
      }
    }
  }
}

/// Drop authors and publishers whose last book disappeared in this merge.
///
/// Like the server, this records no tombstone: it is garbage collection, and a
/// name that comes back in a later snapshot is simply inserted again.
Future<Map<String, int>> _pruneOrphans(DatabaseExecutor db) async {
  final removed = <String, int>{};
  for (final entry in <String, String>{
    'authors': 'DELETE FROM authors WHERE id NOT IN '
        '(SELECT author_id FROM book_authors)',
    'publishers': 'DELETE FROM publishers WHERE id NOT IN '
        '(SELECT publisher_id FROM books WHERE publisher_id IS NOT NULL)',
  }.entries) {
    final before =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM "${entry.key}"'),
        ) ??
        0;
    await db.rawDelete(entry.value);
    final after =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM "${entry.key}"'),
        ) ??
        0;
    removed[entry.key] = before - after;
  }
  return removed;
}

/// Merge one snapshot into the live library, all-or-nothing.
Future<SyncMergeSummary> mergeSnapshot(
  String dbPath,
  File snapshot, {
  String? since,
}) async {
  final meta = await readSnapshotMeta(snapshot);
  final summary = SyncMergeSummary()
    ..sourceDevice = meta.deviceName
    ..sourceGeneration = meta.generation;

  final live = await _openLive(dbPath);
  final remote = await _openReadOnly(snapshot);
  try {
    // ``transaction`` rather than a hand-written BEGIN/COMMIT. Android's sqflite
    // gives a raw BEGIN to the native driver, which then queues every later call
    // from this handle — the COMMIT included — until that transaction ends: it
    // works on the FFI build the tests run on and hangs on a phone. Its own
    // transaction API opens a write transaction on one connection and rolls it
    // back when the callback throws, which is the same guarantee.
    await live.transaction((txn) async {
      await _mergeAll(txn, remote, summary, since);
      final problems = await txn.rawQuery('PRAGMA foreign_key_check');
      if (problems.isNotEmpty) {
        throw SyncException(
          'The merged library failed its consistency check, so nothing was '
          'changed.',
        );
      }
    });
  } finally {
    await remote.close();
    await live.close();
  }
  return summary;
}

// --------------------------------------------------------------------------- //
// Where the shared snapshot lives
// --------------------------------------------------------------------------- //

/// The two ways a phone can reach a shared folder.
///
/// A plain path covers tests and any future desktop build; Android goes through
/// the Storage Access Framework, where the folder is a ``content://`` tree URI
/// the user granted once and Kotlin does the byte shuffling.
abstract class SyncTransport {
  /// Copy the shared snapshot into [target]; false when there is none yet.
  Future<bool> download(File target);

  /// Replace the shared snapshot with [source].
  Future<void> upload(File source);
}

/// A folder on a real filesystem (tests, and the desktop's own path mode).
class FolderSyncTransport implements SyncTransport {
  FolderSyncTransport(this.folder);

  final Directory folder;

  File get snapshot =>
      File('${folder.path}${Platform.pathSeparator}$kSnapshotName');

  @override
  Future<bool> download(File target) async {
    if (!snapshot.existsSync()) return false;
    await snapshot.copy(target.path);
    return true;
  }

  @override
  Future<void> upload(File source) async {
    if (!folder.existsSync()) await folder.create(recursive: true);
    final tmp = File('${snapshot.path}.tmp');
    await source.copy(tmp.path);
    if (snapshot.existsSync()) await snapshot.delete();
    await tmp.rename(snapshot.path);
  }
}

/// Android's folder picker: a persisted tree URI, spoken to over the channel.
class SafSyncTransport implements SyncTransport {
  SafSyncTransport({required this.folderUri, MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kFilesChannel);

  final String folderUri;
  final MethodChannel _channel;

  @override
  Future<bool> download(File target) async {
    try {
      final pulled = await _channel.invokeMethod<bool>('syncPull', <String, Object?>{
        'uri': folderUri,
        'target': target.path,
      });
      return pulled ?? false;
    } on PlatformException catch (error) {
      throw SyncException(error.message ?? 'The shared folder could not be read.');
    }
  }

  @override
  Future<void> upload(File source) async {
    try {
      final pushed = await _channel.invokeMethod<bool>('syncPush', <String, Object?>{
        'uri': folderUri,
        'source': source.path,
      });
      if (pushed != true) {
        throw SyncException('The snapshot could not be written to the shared folder.');
      }
    } on PlatformException catch (error) {
      throw SyncException(
        error.message ?? 'The snapshot could not be written to the shared folder.',
      );
    }
  }
}

// --------------------------------------------------------------------------- //
// Choosing the folder
// --------------------------------------------------------------------------- //

/// A folder the user has granted this app access to.
class SyncFolderChoice {
  const SyncFolderChoice({required this.uri, required this.name});

  /// The ``content://`` tree URI Android remembers.
  final String uri;

  /// What the folder is called, for the settings screen.
  final String name;
}

/// The folder picker, and the questions Dart has to ask Android about a grant.
///
/// Kept apart from [SafSyncTransport] because choosing happens once, while
/// pulling and pushing happen on every sync.
class SharedFolder {
  SharedFolder({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kFilesChannel);

  final MethodChannel _channel;

  /// Ask the user for a folder; ``null`` when they back out.
  ///
  /// Android keeps the grant across restarts, so this happens once per device.
  Future<SyncFolderChoice?> choose() async {
    try {
      final data = await _channel.invokeMethod<Map<Object?, Object?>>(
        'pickSyncFolder',
      );
      if (data == null) return null;
      final uri = '${data['uri'] ?? ''}';
      if (uri.isEmpty) return null;
      return SyncFolderChoice(uri: uri, name: '${data['name'] ?? ''}');
    } on PlatformException catch (error) {
      throw SyncException(error.message ?? 'That folder could not be opened.');
    }
  }

  /// Is the remembered grant still usable? (A reboot, a revoked permission or
  /// an uninstalled provider can all quietly take it away.)
  Future<bool> canWrite(String uri) async {
    try {
      return await _channel.invokeMethod<bool>('syncPermission', <String, Object?>{
            'uri': uri,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// The folder's display name, for a folder stored before its name was.
  Future<String?> nameOf(String uri) async {
    try {
      final name = await _channel.invokeMethod<String>('syncFolderName', <String, Object?>{
        'uri': uri,
      });
      return (name == null || name.isEmpty) ? null : name;
    } on PlatformException {
      return null;
    }
  }
}

// --------------------------------------------------------------------------- //
// Putting it together
// --------------------------------------------------------------------------- //

/// One sync: read the shared snapshot, merge it, publish the result.
///
/// [transport] decides where the snapshot lives, so the same logic runs in
/// tests (a temporary folder) and on a phone (a folder the user picked).
class LibrarySync {
  LibrarySync({
    required this.repo,
    required this.transport,
    Future<Directory> Function()? scratchDirectory,
  }) : _scratchDirectory = scratchDirectory ?? getTemporaryDirectory;

  final LocalRepo repo;
  final SyncTransport transport;
  final Future<Directory> Function() _scratchDirectory;

  static bool _running = false;

  /// Merge the shared snapshot into this library, then publish the result.
  Future<SyncResult> run({bool force = false}) async {
    if (_running) {
      throw SyncException('A sync is already running.');
    }
    _running = true;
    try {
      return await _run(force: force);
    } finally {
      _running = false;
    }
  }

  Future<SyncResult> _run({bool force = false}) async {
    final path = repo.databasePath;
    final name = repo.libraryName;
    if (path == null || name == null) {
      throw SyncException('No local library is open.');
    }
    final dbFile = File(path);
    final stateFile = File(
      '${dbFile.parent.path}${Platform.pathSeparator}$kSyncStateName',
    );
    final state = await SyncState.load(stateFile);
    if (state.deviceId.isEmpty) state.deviceId = newSyncId();
    if (state.deviceName.isEmpty) state.deviceName = defaultDeviceName();

    final scratch = await _scratchDirectory();
    if (!scratch.existsSync()) await scratch.create(recursive: true);
    final remote = File('${scratch.path}${Platform.pathSeparator}$kSnapshotName');

    if (!await transport.download(remote)) {
      // First sync anywhere: publish this library as the starting point.
      final meta = await _exportSnapshot(remote, state: state, generation: 1);
      await transport.upload(remote);
      state.lastSnapshotId = meta.snapshotId;
      final result = SyncResult(snapshot: meta, pushed: true);
      await _finish(state, stateFile, result);
      return result;
    }

    var remoteMeta = await readSnapshotMeta(remote);
    SyncMergeSummary? merge;
    var mergedSnapshot = false;
    final mergedIds = <String>{};
    var attempts = 0;

    while (attempts < kMaxMergeAttempts &&
        remoteMeta.snapshotId != state.lastSnapshotId &&
        !mergedIds.contains(remoteMeta.snapshotId)) {
      await _backup(dbFile);
      // Merge through its own connection. Closing the repo would tear down the
      // handle every open screen is using (and reopening it loses any state the
      // widgets hold), so the live and merge connections coexist; SQLite's
      // busy timeout and WAL handle the hand-off.
      final SyncMergeSummary part = await mergeSnapshot(
        dbFile.path,
        remote,
        since: state.lastSyncAt,
      );
      merge = _combine(merge, part);
      mergedIds.add(remoteMeta.snapshotId);
      state.lastSnapshotId = remoteMeta.snapshotId;
      state.lastSyncAt = nowStamp();
      mergedSnapshot = true;
      attempts++;

      // The folder may have moved on while we were merging: pick up the newer
      // snapshot and merge that too rather than publish over it.
      if (!await transport.download(remote)) break;
      final latest = await readSnapshotMeta(remote);
      if (latest.snapshotId == remoteMeta.snapshotId) break;
      remoteMeta = latest;
    }

    // If the folder moved on after our last merge, we never saw the newest
    // snapshot. Publishing now would overwrite changes we did not merge, so
    // stop and ask the user to retry instead.
    if (remoteMeta.snapshotId != state.lastSnapshotId) {
      throw SyncException(
        'The shared library kept changing while syncing. Please try again.',
      );
    }

    // Only write the file again when the snapshot lacks something we have;
    // otherwise two devices would bounce an unchanged snapshot back and forth.
    final pushed = force || await needsPush(dbFile, remote);
    final SyncSnapshotMeta meta;
    if (pushed) {
      meta = await _exportSnapshot(
        remote,
        state: state,
        basedOn: state.lastSnapshotId,
        generation: remoteMeta.generation + 1,
      );
      await transport.upload(remote);
      state.lastSnapshotId = meta.snapshotId;
    } else {
      meta = remoteMeta;
    }

    final result = SyncResult(
      snapshot: meta,
      merge: merge,
      pushed: pushed,
      mergedSnapshot: mergedSnapshot,
    );
    await _finish(state, stateFile, result);
    return result;
  }

  Future<void> _finish(SyncState state, File stateFile, SyncResult result) async {
    state.lastChangeAt = nowStamp();
    state.lastSyncAt = nowStamp();
    state.lastResult = result.toJson();
    await state.save(stateFile);
  }

  /// A timestamped local copy taken just before a merge; keeps the last ten.
  Future<File> _backup(File dbFile) async {
    final folder = Directory(
      '${dbFile.parent.path}${Platform.pathSeparator}$kBackupFolderName',
    );
    if (!folder.existsSync()) await folder.create(recursive: true);
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final target = File(
      '${folder.path}${Platform.pathSeparator}library-$stamp.db',
    );
    await repo.exportTo(target);
    final backups = folder
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.db'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (var index = 0; index < backups.length - kKeepBackups; index++) {
      try {
        await backups[index].delete();
      } on FileSystemException {
        // A backup we cannot prune is not worth failing the sync over.
      }
    }
    return target;
  }

  /// Write a snapshot of the open library to [target], with its header.
  Future<SyncSnapshotMeta> _exportSnapshot(
    File target, {
    required SyncState state,
    required int generation,
    String? basedOn,
  }) async {
    await repo.exportTo(target);
    final snapshot = await openDatabase(
      target.path,
      singleInstance: false,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
    try {
      // A snapshot is a plain file: no journal left beside it in the shared
      // folder while the metadata is written. A query, because the pragma
      // answers with the new mode and Android's ``execute`` refuses that.
      await snapshot.rawQuery('PRAGMA journal_mode = DELETE');
      await snapshot.execute('DROP TABLE IF EXISTS users');
      await snapshot.execute('DROP TABLE IF EXISTS tokens');
      await snapshot.execute('DROP TABLE IF EXISTS sync_meta');
      // Objectives are per-device metadata: they never travel through a
      // cross-device merge, so a snapshot must not carry them.
      await snapshot.execute('DROP TABLE IF EXISTS reading_goals');
      await snapshot.execute(
        'CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      final counts = await _rowCounts(snapshot);
      final snapshotId = newSyncId();
      final exportedAt = nowStamp();
      final entries = <String, String>{
        'format': '$kSyncFormat',
        'schema_version': '$kLibrarySchemaVersion',
        'snapshot_id': snapshotId,
        'generation': '$generation',
        'exported_at': exportedAt,
        'device_id': state.deviceId,
        'device_name': state.deviceName,
        'based_on': basedOn ?? '',
        'row_counts': jsonEncode(counts),
      };
      final batch = snapshot.batch();
      entries.forEach((key, value) {
        batch.insert('sync_meta', <String, Object?>{'key': key, 'value': value});
      });
      await batch.commit(noResult: true);

      final check = await snapshot.rawQuery('PRAGMA integrity_check');
      if (check.isEmpty || '${check.first.values.first}' != 'ok') {
        throw SyncException('The snapshot copy did not pass its integrity check.');
      }
      return SyncSnapshotMeta(
        format: kSyncFormat,
        schemaVersion: kLibrarySchemaVersion,
        snapshotId: snapshotId,
        generation: generation,
        exportedAt: exportedAt,
        deviceId: state.deviceId,
        deviceName: state.deviceName,
        basedOn: basedOn,
        rowCounts: counts,
      );
    } finally {
      await snapshot.close();
    }
  }
}

Future<Map<String, int>> _rowCounts(DatabaseExecutor db) async {
  final counts = <String, int>{};
  for (final table in <String>[...kRequiredTables, 'sync_tombstones']) {
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM "$table"');
    counts[table] = (rows.first['n'] as int?) ?? 0;
  }
  return counts;
}

SyncMergeSummary _combine(SyncMergeSummary? first, SyncMergeSummary second) {
  if (first == null) return second;
  for (final entry in second.added.entries) {
    first.bump(first.added, entry.key, entry.value);
  }
  for (final entry in second.updated.entries) {
    first.bump(first.updated, entry.key, entry.value);
  }
  for (final entry in second.deleted.entries) {
    first.bump(first.deleted, entry.key, entry.value);
  }
  first.conflicts.addAll(second.conflicts);
  if (second.sourceDevice.isNotEmpty) first.sourceDevice = second.sourceDevice;
  if (second.sourceGeneration != 0) {
    first.sourceGeneration = second.sourceGeneration;
  }
  return first;
}

/// Does the snapshot lack something this library has?
///
/// This is what stops two devices from bouncing an unchanged snapshot back and
/// forth: after a merge the file is only written again when some local row is
/// absent from it, or newer than its copy there.
Future<bool> needsPush(File dbFile, File snapshot) async {
  final live = await _openLive(dbFile.path, readOnly: true);
  final remote = await _openReadOnly(snapshot);
  try {
    final local = await _syncIdsWithStamps(live);
    final remoteRows = await _syncIdsWithStamps(remote);
    for (final entry in local.entries) {
      final other = remoteRows[entry.key] ?? const <String, String>{};
      for (final row in entry.value.entries) {
        final there = other[row.key];
        if (there == null || stampMicros(row.value) > stampMicros(there)) {
          return true;
        }
      }
    }
    return false;
  } finally {
    await remote.close();
    await live.close();
  }
}

Future<Map<String, Map<String, String>>> _syncIdsWithStamps(
  DatabaseExecutor db,
) async {
  final out = <String, Map<String, String>>{};
  for (final table in kSyncedTables) {
    final rows = await db.rawQuery(
      'SELECT sync_id, updated_at FROM "$table" WHERE sync_id IS NOT NULL',
    );
    out[table] = <String, String>{
      for (final row in rows) '${row['sync_id']}': '${row['updated_at'] ?? ''}',
    };
  }
  final tombstones = await db.rawQuery(
    'SELECT table_name, sync_id, deleted_at FROM sync_tombstones',
  );
  out['tombstones'] = <String, String>{
    for (final row in tombstones)
      '${row['table_name']}/${row['sync_id']}': '${row['deleted_at'] ?? ''}',
  };
  return out;
}
