/// Small UI helpers shared by every screen.
library;

import 'package:flutter/material.dart';

import '../core/api_exception.dart';
import 'l10n_scope.dart';

/// Turn any thrown object into something worth showing a user.
///
/// Messages the server sends back are already in the app's language (the client
/// asks for it with ``Accept-Language``), so they pass through untouched. The
/// ones the app invents are English source strings, and go through the
/// catalogue like every other label.
String describeError(BuildContext context, Object error) {
  final message = error is ApiException ? error.message : error.toString();
  return context.localized.tr(message);
}

void showSnack(BuildContext context, String message, {bool isError = false}) {
  if (!context.mounted) return;
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              size: 18,
              color: isError ? scheme.error : const Color(0xFF34D399),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
}

/// Ask for one line of text — a library name, say.
///
/// Returns ``null`` when the user cancels, and the trimmed text (possibly
/// empty) when they confirm, so the caller decides what an empty answer means.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  String? message,
  String? initial,
  String? label,
  String? hint,
  String? confirmLabel,
  IconData? icon,
}) async {
  final l10n = context.localized;
  final controller = TextEditingController(text: initial ?? '');
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message != null) ...[
              Text(message),
              const SizedBox(height: 14),
            ],
            TextField(
              controller: controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: label,
                hintText: hint,
                prefixIcon: icon == null ? null : Icon(icon),
              ),
              onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(confirmLabel ?? l10n.tr('Confirm')),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

/// Ask before doing something that cannot be undone.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
  bool destructive = false,
}) async {
  final l10n = context.localized;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.tr('Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error)
              : null,
          child: Text(confirmLabel ?? l10n.tr('Confirm')),
        ),
      ],
    ),
  );
  return result ?? false;
}
