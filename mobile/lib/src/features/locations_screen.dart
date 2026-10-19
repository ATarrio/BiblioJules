import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_exception.dart';
import '../core/models/models.dart';
import '../core/providers.dart';
import '../core/util.dart';
import '../theme.dart';
import '../widgets/app_bar.dart';
import '../widgets/async_view.dart';
import '../widgets/feedback.dart';
import '../widgets/form_fields.dart';
import '../widgets/guarded.dart';
import '../widgets/l10n_scope.dart';
import '../widgets/picker_sheet.dart';

/// The shelf/room/box tree, with the same add/edit/delete the web app has.
class LocationsScreen extends ConsumerWidget {
  const LocationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.localized;
    final locations = ref.watch(locationsProvider);
    return Scaffold(
      appBar: LibraryAppBar(title: l10n.tr('Locations')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showLocationDialog(context, ref, all: locations.value ?? const []),
        icon: const Icon(Icons.add),
        label: Text(l10n.tr('Add location')),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(locationsProvider);
          try {
            await ref.read(locationsProvider.future);
          } on Object {
            // Rendered below.
          }
        },
        child: AsyncView<List<Location>>(
          value: locations,
          onRetry: () => ref.invalidate(locationsProvider),
          builder: (items) {
            if (items.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.5,
                    child: EmptyState(
                      message: l10n.tr('No locations yet.'),
                      icon: Icons.warehouse_outlined,
                    ),
                  ),
                ],
              );
            }
            final ordered = orderedLocations(items);
            final counts = _bookCounts(ref);
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: ordered.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final (location, depth) = ordered[index];
                final count = counts[location.id];
                return ListTile(
                  contentPadding: EdgeInsets.only(left: 16 + depth * 20, right: 8),
                  leading: Icon(
                    location.parentId == null
                        ? Icons.warehouse_outlined
                        : Icons.subdirectory_arrow_right,
                    color: kSlate400,
                  ),
                  title: Text(location.name),
                  subtitle: Text(
                    [
                      if (location.kind != null && location.kind!.isNotEmpty)
                        location.kind!,
                      if (count != null)
                        l10n.tn('%d book', '%d books', count),
                      if (location.description != null &&
                          location.description!.isNotEmpty)
                        location.description!,
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) async {
                      switch (value) {
                        case 'edit':
                          await showLocationDialog(
                            context,
                            ref,
                            location: location,
                            all: items,
                          );
                        case 'child':
                          await showLocationDialog(
                            context,
                            ref,
                            parentId: location.id,
                            all: items,
                          );
                        case 'delete':
                          final confirmed = await confirmAction(
                            context,
                            title: l10n.tr('Delete location'),
                            message: l10n.tr(
                              'Delete “%(name)s”? Books on it keep their record but lose the shelf.',
                              {'name': location.name},
                            ),
                            confirmLabel: l10n.tr('Delete'),
                            destructive: true,
                          );
                          if (!confirmed || !context.mounted) return;
                          final done = await runGuarded(
                            context,
                            ref,
                            () => ref.read(repoProvider).deleteLocation(location.id),
                          );
                          if (done == null) return;
                          invalidateLocations(ref);
                          if (context.mounted) {
                            showSnack(context, l10n.tr('Location deleted.'));
                          }
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(value: 'edit', child: Text(l10n.tr('Edit'))),
                      PopupMenuItem(
                        value: 'child',
                        child: Text(l10n.tr('Add a location inside it')),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          l10n.tr('Delete'),
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                  onTap: () => showLocationDialog(
                    context,
                    ref,
                    location: location,
                    all: items,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// How many books sit on each shelf, taken from the cached catalogue.
  Map<int, int> _bookCounts(WidgetRef ref) {
    final books = ref.watch(booksProvider).value;
    final counts = <int, int>{};
    if (books == null) return counts;
    for (final book in books) {
      final id = book.locationId;
      if (id == null) continue;
      counts[id] = (counts[id] ?? 0) + 1;
    }
    return counts;
  }
}

/// Add or edit one location. Returns true when something was saved.
Future<bool> showLocationDialog(
  BuildContext context,
  WidgetRef ref, {
  Location? location,
  int? parentId,
  required List<Location> all,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) =>
        _LocationDialog(location: location, parentId: parentId, all: all),
  );
  return saved ?? false;
}

class _LocationDialog extends ConsumerStatefulWidget {
  const _LocationDialog({this.location, this.parentId, required this.all});

  final Location? location;
  final int? parentId;
  final List<Location> all;

  @override
  ConsumerState<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends ConsumerState<_LocationDialog> {
  late final TextEditingController _name;
  late final TextEditingController _kind;
  late final TextEditingController _description;
  int? _parentId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.location?.name ?? '');
    _kind = TextEditingController(text: widget.location?.kind ?? '');
    _description = TextEditingController(text: widget.location?.description ?? '');
    _parentId = widget.location?.parentId ?? widget.parentId;
  }

  @override
  void dispose() {
    _name.dispose();
    _kind.dispose();
    _description.dispose();
    super.dispose();
  }

  /// A location may not be filed inside itself.
  List<Location> get _parentOptions => [
    for (final item in widget.all)
      if (item.id != widget.location?.id) item,
  ];

  Future<void> _save() async {
    final l10n = context.localized;
    if (_name.text.trim().isEmpty) {
      showSnack(context, l10n.tr('A name is required.'), isError: true);
      return;
    }
    setState(() => _busy = true);
    final api = ref.read(repoProvider);
    try {
      if (widget.location == null) {
        await api.createLocation(
          name: _name.text.trim(),
          parentId: _parentId,
          kind: _blank(_kind.text),
          description: _blank(_description.text),
        );
      } else {
        await api.updateLocation(
          widget.location!.id,
          name: _name.text.trim(),
          parentId: _parentId,
          kind: _blank(_kind.text),
          description: _blank(_description.text),
        );
      }
      invalidateLocations(ref);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiAuthException catch (error) {
      await ref.read(sessionProvider.notifier).handleRejectedToken(error.message);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, error.message, isError: true);
    }
  }

  String? _blank(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final isEdit = widget.location != null;
    return AlertDialog(
      title: Text(isEdit ? l10n.tr('Edit location') : l10n.tr('Add location')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: !isEdit,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l10n.tr('Name')),
            ),
            const SizedBox(height: 14),
            PickerField(
              label: l10n.tr('Inside'),
              icon: Icons.account_tree_outlined,
              clearable: true,
              value: _parentName(),
              onClear: () => setState(() => _parentId = null),
              onTap: () async {
                final ordered = orderedLocations(_parentOptions);
                final picked = await showPickerSheet<int>(
                  context,
                  title: l10n.tr('Inside'),
                  selected: _parentId,
                  options: [
                    for (final (item, depth) in ordered)
                      PickerOption(
                        item.id,
                        '${'—' * depth}${depth > 0 ? ' ' : ''}${item.name}',
                      ),
                  ],
                );
                if (picked != null) setState(() => _parentId = picked.value);
              },
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _kind,
              decoration: InputDecoration(
                labelText: l10n.tr('Kind'),
                hintText: l10n.tr('room, bookcase, shelf, box…'),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _description,
              maxLines: 2,
              decoration: InputDecoration(labelText: l10n.tr('Description')),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.tr('Cancel')),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(l10n.tr('Save')),
        ),
      ],
    );
  }

  String? _parentName() {
    if (_parentId == null) return null;
    for (final item in widget.all) {
      if (item.id == _parentId) return item.name;
    }
    return null;
  }
}
