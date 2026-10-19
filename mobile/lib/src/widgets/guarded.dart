/// The one place API calls are made from a screen: it shows failures as a
/// snack bar and signs the user out when the server rejects the token.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_exception.dart';
import '../core/providers.dart';
import '../widgets/feedback.dart';

/// Run [action], reporting problems to the user instead of throwing.
///
/// Returns the value on success and ``null`` on failure, so callers can simply
/// check for null (or use [onError] to react).
Future<T?> runGuarded<T>(
  BuildContext context,
  WidgetRef ref,
  Future<T> Function() action, {
  String? successMessage,
  void Function(ApiException error)? onError,
}) async {
  try {
    final result = await action();
    if (successMessage != null && context.mounted) {
      showSnack(context, successMessage);
    }
    return result;
  } on ApiAuthException catch (error) {
    await ref.read(sessionProvider.notifier).handleRejectedToken(error.message);
    onError?.call(error);
    return null;
  } on ApiException catch (error) {
    if (context.mounted) showSnack(context, error.message, isError: true);
    onError?.call(error);
    return null;
  }
}
