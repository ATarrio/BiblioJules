/// Fixed vocabularies for book attributes.
///
/// These mirror ``app/book_fields.py`` in the server: the slugs are what the
/// API stores, and the values are the English labels, which double as the
/// translation keys (see [L10n]).
library;

/// Cover type slug -> English label (the translation key).
const Map<String, String> kCoverTypes = {
  'hardcover': 'Hardcover',
  'paperback': 'Paperback',
  'ebook': 'Ebook',
  'audiobook': 'Audiobook',
  'pocket': 'Pocket',
  'other': 'Other',
};

/// Reading status slug -> English label.
const Map<String, String> kReadStatuses = {
  'unread': 'Unread',
  'to_read': 'To Be Read',
  'currently_reading': 'Currently Reading',
  'read': 'Read',
  'dnf': 'DNF',
};

/// A score runs from one to five stars, in half-star steps. Zero means
/// "not rated" and is never stored.
const double kMinScore = 1.0;
const double kMaxScore = 5.0;
const double kScoreStep = 0.5;

/// The English label for [slug], or an empty string when unset (mirrors
/// ``cover_type_label``/``read_status_label``).
String coverTypeLabel(String? slug) => kCoverTypes[slug ?? ''] ?? '';

String readStatusLabel(String? slug) => kReadStatuses[slug ?? ''] ?? '';

/// Render a score as filled/half/empty stars, e.g. ``★★★½☆``.
String scoreStars(double? score) {
  if (score == null || score <= 0) return '';
  final full = score.floor();
  final half = (score - full) >= kScoreStep - 1e-9;
  final empty = 5 - full - (half ? 1 : 0);
  return '★' * full + (half ? '½' : '') + '☆' * (empty < 0 ? 0 : empty);
}

/// Strip the formatting off a scanned or typed ISBN, keeping digits and an X
/// (mirrors ``isbn_lookup.normalize_isbn`` on the server).
String normalizeIsbn(String raw) =>
    raw.replaceAll(RegExp(r'[^0-9Xx]'), '').toUpperCase();

/// The year inside a free-form date, or ``null`` when there is none.
///
/// Mirrors ``isbn_lookup.extract_year``: anything from 1500 to 2099 that looks
/// like a year counts, so ``1965``, ``2019-04-23`` and ``April 2019`` all work,
/// while a date written as ``MMV`` yields nothing.
int? extractYear(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  final match = RegExp(r'(1[5-9]\d\d|20\d\d)').firstMatch('$value');
  return match == null ? null : int.parse(match.group(1)!);
}
