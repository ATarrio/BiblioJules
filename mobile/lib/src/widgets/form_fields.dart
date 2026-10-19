/// Small, reusable inputs — the mobile equivalents of the desktop's steppers
/// and the web form's compact widgets.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/book_fields.dart';
import '../theme.dart';
import 'l10n_scope.dart';

/// A form field that opens a picker sheet instead of the keyboard.
class PickerField extends StatelessWidget {
  const PickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    this.icon,
    this.clearable = false,
    this.onClear,
  });

  final String label;
  final String? value;
  final VoidCallback onTap;
  final IconData? icon;
  final bool clearable;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final hasValue = value != null && value!.isNotEmpty;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: icon == null ? null : Icon(icon, size: 20),
          suffixIcon: hasValue && clearable
              ? IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: l10n.tr('Clear'),
                  onPressed: onClear,
                )
              : const Icon(Icons.arrow_drop_down),
        ),
        child: Text(
          hasValue ? value! : l10n.tr('Not set'),
          style: TextStyle(color: hasValue ? null : kSlate500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// One to five stars in half-star steps, with the desktop's −/+ buttons and a
/// way back to "unrated".
class ScoreField extends StatelessWidget {
  const ScoreField({super.key, required this.value, required this.onChanged});

  final double? value;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final current = value;
    return Row(
      children: [
        Text(l10n.tr('Score'), style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(width: 12),
        IconButton.filledTonal(
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          tooltip: l10n.tr('Decrease'),
          onPressed: current == null
              ? null
              : () => onChanged(
                  current - kScoreStep < kMinScore ? null : current - kScoreStep,
                ),
          icon: const Icon(Icons.remove),
        ),
        Expanded(
          child: Center(
            child: Text(
              current == null ? l10n.tr('Not rated') : scoreStars(current),
              style: TextStyle(
                fontSize: 20,
                color: current == null ? kSlate500 : kAmber,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ),
        IconButton.filledTonal(
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          tooltip: l10n.tr('Increase'),
          onPressed: current == null
              ? () => onChanged(kMinScore)
              : (current >= kMaxScore
                    ? null
                    : () => onChanged(current + kScoreStep)),
          icon: const Icon(Icons.add),
        ),
        if (current != null)
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            tooltip: l10n.tr('Clear'),
            onPressed: () => onChanged(null),
            icon: const Icon(Icons.backspace_outlined),
          ),
      ],
    );
  }
}

/// A compact integer stepper (saga numbers, and anything else counting).
class NumberStepper extends StatelessWidget {
  const NumberStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.placeholder = '—',
  });

  final int? value;
  final ValueChanged<int?> onChanged;
  final String? label;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final current = value;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          tooltip: l10n.tr('Decrease'),
          onPressed: current == null
              ? null
              : () => onChanged(current - 1 < 1 ? null : current - 1),
          icon: const Icon(Icons.remove),
        ),
        SizedBox(
          width: 40,
          child: Center(
            child: Text(
              current == null ? placeholder : '$current',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: current == null ? kSlate500 : null,
              ),
            ),
          ),
        ),
        IconButton.filledTonal(
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          tooltip: l10n.tr('Increase'),
          onPressed: () => onChanged(current == null ? 1 : current + 1),
          icon: const Icon(Icons.add),
        ),
      ],
    );
    if (label == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label!, style: Theme.of(context).textTheme.labelLarge),
        row,
      ],
    );
  }
}

/// The five fixed reading statuses as chips; tapping the active one clears it.
class ReadStatusChips extends StatelessWidget {
  const ReadStatusChips({super.key, required this.value, required this.onChanged});

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.tr('Read status'),
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in kReadStatuses.entries)
              ChoiceChip(
                label: Text(l10n.tr(entry.value)),
                selected: value == entry.key,
                onSelected: (selected) => onChanged(selected ? entry.key : null),
              ),
          ],
        ),
      ],
    );
  }
}

/// Cover type (also a fixed vocabulary) as chips.
class CoverTypeChips extends StatelessWidget {
  const CoverTypeChips({super.key, required this.value, required this.onChanged});

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.tr('Cover type'), style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in kCoverTypes.entries)
              ChoiceChip(
                label: Text(l10n.tr(entry.value)),
                selected: value == entry.key,
                onSelected: (selected) => onChanged(selected ? entry.key : null),
              ),
          ],
        ),
      ],
    );
  }
}

/// A published date that accepts a year, a year-month or a full date (the same
/// three shapes the server stores), with a calendar button for the exact day.
class PublishedDateField extends StatelessWidget {
  const PublishedDateField({
    super.key,
    required this.controller,
    required this.onPicked,
  });

  final TextEditingController controller;
  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.datetime,
      decoration: InputDecoration(
        labelText: l10n.tr('Published'),
        hintText: l10n.tr('Year, year-month or full date'),
        prefixIcon: const Icon(Icons.event_outlined),
        suffixIcon: IconButton(
          icon: const Icon(Icons.calendar_month),
          tooltip: l10n.tr('Pick a date'),
          onPressed: () async {
            final now = DateTime.now();
            final initial = DateTime.tryParse(controller.text.trim()) ?? now;
            final picked = await showDatePicker(
              context: context,
              initialDate: initial,
              firstDate: DateTime(1400),
              lastDate: DateTime(now.year + 5, 12, 31),
              helpText: l10n.tr('Published'),
            );
            if (picked != null) {
              final value =
                  '${picked.year.toString().padLeft(4, '0')}-'
                  '${picked.month.toString().padLeft(2, '0')}-'
                  '${picked.day.toString().padLeft(2, '0')}';
              controller.text = value;
              onPicked(value);
            }
          },
        ),
      ),
    );
  }
}

/// A text field that only accepts digits (ISBNs and page counts also accept
/// their own punctuation, handled by the caller).
class DigitsOnlyFormatter extends TextInputFormatter {
  const DigitsOnlyFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.text.isEmpty || RegExp(r'^\d+$').hasMatch(newValue.text)
        ? newValue
        : oldValue;
  }
}
