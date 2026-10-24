import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/csv_import.dart';
import '../../core/providers.dart';
import '../../theme.dart';
import '../../widgets/app_bar.dart';
import '../../widgets/feedback.dart';
import '../../widgets/guarded.dart';
import '../../widgets/l10n_scope.dart';

/// Upload a Goodreads/StoryGraph CSV, pick rows and import them.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  final List<ImportRow> _allRows = [];
  final List<ImportRow> _rows = [];
  String? _fileName;
  bool _onlyToRead = false;
  bool _busy = false;
  int _done = 0;
  int _total = 0;

  Future<void> _pickFile() async {
    final l10n = context.localized;
    setState(() => _busy = true);
    try {
      final file = await ref
          .read(deviceFilePickerProvider)
          .pick(name: 'import.csv');
      if (file == null) return;
      try {
        final length = await file.length();
        if (length > kMaxCsvBytes) {
          throw ApiValidationException(
            l10n.tr('That file is too large (the limit is 20 MB).'),
          );
        }
        final text = utf8.decode(
          await file.readAsBytes(),
          allowMalformed: true,
        );
        final rows = parseImportCsv(text);
        if (rows.isEmpty) {
          throw ApiValidationException(l10n.tr('No rows found in that CSV.'));
        }
        if (rows.length > kMaxImportRows) {
          throw ApiValidationException(
            l10n.tr('That CSV has too many rows (the limit is %(count)s).', {
              'count': kMaxImportRows,
            }),
          );
        }
        if (!mounted) return;
        setState(() {
          _fileName = 'import.csv';
          _allRows.clear();
          _allRows.addAll(rows);
          _filterRows();
        });
      } finally {
        if (await file.exists()) await file.delete();
      }
    } on ApiException catch (error) {
      if (mounted) showSnack(context, error.message, isError: true);
    } on Object catch (error) {
      if (mounted) {
        showSnack(context, describeError(context, error), isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final l10n = context.localized;
    final selected = _rows.where((row) => row.selected).toList();
    if (selected.isEmpty) {
      showSnack(
        context,
        l10n.tr('Select at least one row first.'),
        isError: true,
      );
      return;
    }
    setState(() {
      _busy = true;
      _done = 0;
      _total = selected.length;
    });
    final outcome = await runGuarded<ImportOutcome>(
      context,
      ref,
      () => importRows(
        ref.read(repoProvider),
        selected,
        onProgress: (done, total) {
          if (mounted) setState(() => _done = done);
        },
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (outcome == null) return;
    invalidateBooks(ref);
    invalidateReading(ref);
    ref.invalidate(wantListProvider);
    await _showResult(outcome);
    if (mounted) context.pop();
  }

  Future<void> _showResult(ImportOutcome outcome) async {
    final l10n = context.localized;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.tr('Import finished')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.tr(
                'Imported %(imported)s book(s), skipped %(skipped)s duplicate(s), and added %(want)s to the want-to-read list.',
                {
                  'imported': outcome.imported,
                  'skipped': outcome.skipped,
                  'want': outcome.addedToWantList,
                },
              ),
            ),
            if (outcome.errors.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                l10n.tr('Some rows failed:'),
                style: const TextStyle(
                  color: kRed,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(outcome.errors.take(5).join('\n')),
            ],
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.tr('Done')),
          ),
        ],
      ),
    );
  }

  void _setAll(bool selected) {
    setState(() {
      for (final row in _rows) {
        row.selected = selected;
      }
    });
  }

  void _toggleOnlyToRead(bool? value) {
    setState(() {
      _onlyToRead = value ?? false;
      _filterRows();
    });
  }

  void _filterRows() {
    _rows.clear();
    for (final row in _allRows) {
      if (_onlyToRead &&
          '${row.data['read_status'] ?? ''}'.trim() != 'to_read') {
        continue;
      }
      _rows.add(row);
    }
    // Re-select all rows after re-filtering, matching desktop behaviour
    // where every row starts selected.
    for (final row in _rows) {
      row.selected = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final selected = _rows.where((row) => row.selected).length;
    return Scaffold(
      appBar: LibraryAppBar(
        title: l10n.tr('Import a CSV'),
        actions: [
          IconButton(
            tooltip: l10n.tr('Choose a CSV file'),
            icon: const Icon(Icons.folder_open),
            onPressed: _busy ? null : _pickFile,
          ),
        ],
        showSync: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: Text(
                _fileName ?? l10n.tr('Choose a CSV file'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                l10n.tr(
                  'Goodreads, StoryGraph, or any CSV with ISBN, title and author columns.',
                ),
              ),
              trailing: FilledButton(
                onPressed: _busy ? null : _pickFile,
                child: Text(l10n.tr('Choose')),
              ),
            ),
          ),
          CheckboxListTile(
            value: _onlyToRead,
            onChanged: _busy ? null : _toggleOnlyToRead,
            title: Text(l10n.tr('Only import books with "to-read" status')),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
            if (_total > 0) ...[
              const SizedBox(height: 4),
              Text(
                l10n.tr('%(done)s of %(total)s row(s)', {
                  'done': _done,
                  'total': _total,
                }),
                style: const TextStyle(color: kSlate500),
              ),
            ],
          ],
          if (_rows.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.tr('%(count)s row(s) ready.', {'count': _rows.length}),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _setAll(true),
                  child: Text(l10n.tr('Select all')),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _setAll(false),
                  child: Text(l10n.tr('Clear selection')),
                ),
              ],
            ),
            for (final row in _rows)
              CheckboxListTile(
                value: row.selected,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => row.selected = value ?? false),
                title: Text(
                  row.title.isEmpty ? l10n.tr('(untitled)') : row.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    if (row.authors.isNotEmpty) row.authors,
                    if (row.isbn != null) 'ISBN ${row.isbn}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy || selected == 0 ? null : _import,
              icon: const Icon(Icons.download_done),
              label: Text(
                l10n.tr('Import %(count)s selected', {'count': selected}),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
