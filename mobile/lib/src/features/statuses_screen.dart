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
import '../widgets/guarded.dart';
import '../widgets/l10n_scope.dart';

/// The shelf labels ("Owned", "Wishlist", "Borrowed"…), fully editable.
class StatusesScreen extends ConsumerWidget {
  const StatusesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.localized;
    final statuses = ref.watch(statusesProvider);
    return Scaffold(
      appBar: LibraryAppBar(title: l10n.tr('Statuses')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showStatusDialog(context, ref),
        icon: const Icon(Icons.add),
        label: Text(l10n.tr('Add status')),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(statusesProvider);
          try {
            await ref.read(statusesProvider.future);
          } on Object {
            // Rendered below.
          }
        },
        child: AsyncView<List<Status>>(
          value: statuses,
          onRetry: () => ref.invalidate(statusesProvider),
          builder: (items) {
            if (items.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.5,
                    child: EmptyState(
                      message: l10n.tr('No statuses yet.'),
                      icon: Icons.label_outline,
                    ),
                  ),
                ],
              );
            }
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: items.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final status = items[index];
                final color = parseHexColor(status.color);
                return ListTile(
                  leading: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  title: Row(
                    children: [
                      Flexible(child: Text(status.name)),
                      if (status.isDefault) ...[
                        const SizedBox(width: 8),
                        _Tag(label: l10n.tr('Default'), color: kBrand),
                      ],
                      if (status.isSystem) ...[
                        const SizedBox(width: 6),
                        _Tag(label: l10n.tr('Built-in'), color: kSlate500),
                      ],
                    ],
                  ),
                  subtitle: status.description == null || status.description!.isEmpty
                      ? (status.slug == null ? null : Text(status.slug!))
                      : Text(status.description!),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) async {
                      if (value == 'edit') {
                        await showStatusDialog(context, ref, status: status);
                        return;
                      }
                      final confirmed = await confirmAction(
                        context,
                        title: l10n.tr('Delete status'),
                        message: l10n.tr(
                          'Delete “%(name)s”? Books on it keep their record but lose the label.',
                          {'name': status.name},
                        ),
                        confirmLabel: l10n.tr('Delete'),
                        destructive: true,
                      );
                      if (!confirmed || !context.mounted) return;
                      final done = await runGuarded(
                        context,
                        ref,
                        () => ref.read(repoProvider).deleteStatus(status.id),
                      );
                      if (done == null) return;
                      invalidateStatuses(ref);
                      if (context.mounted) {
                        showSnack(context, l10n.tr('Status deleted.'));
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(value: 'edit', child: Text(l10n.tr('Edit'))),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          l10n.tr('Delete'),
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                  onTap: () => showStatusDialog(context, ref, status: status),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}

/// The colour swatches offered when creating or editing a status.
const List<String> kStatusColors = [
  '#64748b',
  '#3366f2',
  '#a78bfa',
  '#34d399',
  '#f59e0b',
  '#f87171',
  '#22d3ee',
  '#f472b6',
];

Future<bool> showStatusDialog(
  BuildContext context,
  WidgetRef ref, {
  Status? status,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => _StatusDialog(status: status),
  );
  return saved ?? false;
}

class _StatusDialog extends ConsumerStatefulWidget {
  const _StatusDialog({this.status});

  final Status? status;

  @override
  ConsumerState<_StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends ConsumerState<_StatusDialog> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _icon;
  late String _color;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.status?.name ?? '');
    _description = TextEditingController(text: widget.status?.description ?? '');
    _icon = TextEditingController(text: widget.status?.icon ?? '');
    _color = normalizeHexColor(widget.status?.color ?? kStatusColors.first);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _icon.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = context.localized;
    if (_name.text.trim().isEmpty) {
      showSnack(context, l10n.tr('A name is required.'), isError: true);
      return;
    }
    setState(() => _busy = true);
    final api = ref.read(repoProvider);
    try {
      if (widget.status == null) {
        await api.createStatus(
          name: _name.text.trim(),
          color: _color,
          icon: _blank(_icon.text),
          description: _blank(_description.text),
        );
      } else {
        await api.updateStatus(
          widget.status!.id,
          name: _name.text.trim(),
          color: _color,
          icon: _blank(_icon.text),
          description: _blank(_description.text),
        );
      }
      invalidateStatuses(ref);
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
    final isEdit = widget.status != null;
    return AlertDialog(
      title: Text(isEdit ? l10n.tr('Edit status') : l10n.tr('Add status')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: !isEdit,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l10n.tr('Name')),
            ),
            const SizedBox(height: 16),
            Text(l10n.tr('Colour'), style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final hex in kStatusColors)
                  GestureDetector(
                    onTap: () => setState(() => _color = hex),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: parseHexColor(hex),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color == hex ? kSlate100 : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _icon,
              decoration: InputDecoration(
                labelText: l10n.tr('Icon'),
                hintText: l10n.tr('An emoji or short label'),
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
}
