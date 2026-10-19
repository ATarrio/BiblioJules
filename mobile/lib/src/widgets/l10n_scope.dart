/// Makes the current string catalogue available to every widget.
///
/// The app wraps MaterialApp in an [L10nScope]; because the scope is rebuilt
/// whenever the language changes, any widget below it can read strings
/// synchronously through ``context.localized``.
library;

import 'package:flutter/widgets.dart';

import '../core/l10n.dart';

class L10nScope extends InheritedWidget {
  const L10nScope({super.key, required this.l10n, required super.child});

  final L10n l10n;

  static L10n of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<L10nScope>();
    assert(scope != null, 'L10nScope is missing from the widget tree.');
    return scope!.l10n;
  }

  @override
  bool updateShouldNotify(L10nScope oldWidget) => oldWidget.l10n != l10n;
}

extension L10nBuildContextX on BuildContext {
  /// The string catalogue for the current language.
  L10n get localized => L10nScope.of(this);

  /// Shorthand for ``context.localized.tr(...)``.
  String tr(String source, [Map<String, Object?>? args]) =>
      L10nScope.of(this).tr(source, args);
}
