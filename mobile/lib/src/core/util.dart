/// Small helpers that are worth unit-testing on their own.
library;

import 'package:intl/intl.dart';

import 'models/models.dart';

/// Flatten a location tree into ``(location, depth)`` pairs in display order.
///
/// The API returns a flat list, so the parent relationships are walked here.
/// Anything whose parent is missing from the list is appended at depth 0 rather
/// than silently dropped.
List<(Location, int)> orderedLocations(List<Location> locations) {
  final byParent = <int?, List<Location>>{};
  for (final location in locations) {
    byParent.putIfAbsent(location.parentId, () => []).add(location);
  }

  final out = <(Location, int)>[];
  final seen = <int>{};

  void walk(int? parent, int depth) {
    final children = List<Location>.from(byParent[parent] ?? const <Location>[]);
    children.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    for (final child in children) {
      if (!seen.add(child.id)) continue;
      out.add((child, depth));
      walk(child.id, depth + 1);
    }
  }

  walk(null, 0);
  for (final location in locations) {
    if (seen.add(location.id)) out.add((location, 0));
  }
  return out;
}

/// Turn a human name into a slug, mirroring the server's ``library.slugify``.
///
/// Used for both status URLs and local library file names, so the same name
/// produces the same slug everywhere. [fallback] is returned when nothing
/// usable survives (a name made entirely of punctuation, say).
String slugify(String value, {String fallback = 'status'}) {
  var text = value.toLowerCase();
  // Drop anything that is not a word character, whitespace or a dash. Dart's
  // ``\w`` is ASCII-only, which is what a slug wants.
  text = text.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
  text = text.replaceAll(RegExp(r'[\s_-]+'), '-');
  return text.isEmpty ? fallback : text;
}

/// Normalise a hex colour typed or picked by the user.
String normalizeHexColor(String value, {String fallback = '#64748b'}) {
  var hex = value.trim().replaceFirst('#', '');
  if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
  if (hex.length != 6 || int.tryParse(hex, radix: 16) == null) return fallback;
  return '#${hex.toLowerCase()}';
}

/// Render an ISO date (``2024-05-01``, possibly with a time) in the reader's
/// language, e.g. ``1 may 2024``.
///
/// Falls back to the raw string whenever the date is not parseable or the
/// locale data has not been loaded, so a display is never lost to formatting.
String formatDate(String? value, String language) {
  if (value == null || value.trim().isEmpty) return '';
  final trimmed = value.trim();
  final date = DateTime.tryParse(trimmed);
  if (date == null) return trimmed;
  try {
    return DateFormat.yMMMd(language).format(date);
  } on Object {
    return trimmed;
  }
}
