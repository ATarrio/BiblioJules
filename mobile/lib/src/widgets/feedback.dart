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
