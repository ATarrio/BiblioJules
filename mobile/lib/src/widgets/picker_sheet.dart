/// A searchable single-choice bottom sheet, used for shelves, locations,
/// authors, publishers and sagas.
library;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'l10n_scope.dart';

class PickerOption<T> {
  const PickerOption(this.value, this.label, {this.subtitle, this.color});

  final T value;
  final String label;
  final String? subtitle;
  final Color? color;
}

/// The result of [showPickerSheet]; ``value == null`` means "clear it".
class Picked<T> {
  const Picked(this.value);

  final T? value;
}

/// Returns ``null`` when the sheet was dismissed without choosing.
Future<Picked<T>?> showPickerSheet<T>(
  BuildContext context, {
  required String title,
  required List<PickerOption<T>> options,
  T? selected,
  bool allowClear = true,
  String? clearLabel,
  String? emptyMessage,
}) {
  return showModalBottomSheet<Picked<T>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.75,
    ),
    builder: (context) => _PickerSheet<T>(
      title: title,
      options: options,
      selected: selected,
      allowClear: allowClear,
      clearLabel: clearLabel,
      emptyMessage: emptyMessage,
    ),
  );
}

class _PickerSheet<T> extends StatefulWidget {
  const _PickerSheet({
    required this.title,
    required this.options,
    required this.selected,
    required this.allowClear,
    this.clearLabel,
    this.emptyMessage,
  });

  final String title;
  final List<PickerOption<T>> options;
  final T? selected;
  final bool allowClear;
  final String? clearLabel;
  final String? emptyMessage;

  @override
  State<_PickerSheet<T>> createState() => _PickerSheetState<T>();
}

class _PickerSheetState<T> extends State<_PickerSheet<T>> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final matches = widget.query(_query);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (widget.allowClear)
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(const Picked(null)),
                    icon: const Icon(Icons.backspace_outlined, size: 16),
                    label: Text(widget.clearLabel ?? l10n.tr('Clear')),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              autofocus: false,
              decoration: InputDecoration(
                hintText: l10n.tr('Search…'),
                prefixIcon: const Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: matches.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      widget.emptyMessage ?? l10n.tr('Nothing to choose from.'),
                      style: const TextStyle(color: kSlate500),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final option = matches[index];
                      final isSelected = option.value == widget.selected;
                      return ListTile(
                        dense: true,
                        leading: option.color == null
                            ? Icon(
                                isSelected
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                size: 20,
                                color: isSelected ? kBrand : kSlate500,
                              )
                            : Icon(Icons.circle, size: 16, color: option.color),
                        title: Text(option.label),
                        subtitle: option.subtitle == null ? null : Text(option.subtitle!),
                        selected: isSelected,
                        onTap: () =>
                            Navigator.of(context).pop(Picked<T>(option.value)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

extension _PickerSheetQuery<T> on _PickerSheet<T> {
  List<PickerOption<T>> query(String needle) {
    if (needle.trim().isEmpty) return options;
    final lower = needle.trim().toLowerCase();
    return options
        .where(
          (option) =>
              option.label.toLowerCase().contains(lower) ||
              (option.subtitle?.toLowerCase().contains(lower) ?? false),
        )
        .toList();
  }
}
