/// Identifiers that survive a trip between devices.
///
/// The integer ``id`` of a row is only meaningful inside one SQLite file: two
/// phones both start counting at 1. Sharing a library therefore needs a second
/// key that is unique across every device, written once when the row is created
/// and never reused — even after the row is deleted and another one takes its
/// place. This mirrors ``new_sync_id`` in ``app/models/common.py``.
library;

import 'dart:math';

const String _hexDigits = '0123456789abcdef';

final Random _random = Random.secure();

/// A 32-character random identifier, in the same shape a server writes.
String newSyncId() {
  final buffer = StringBuffer();
  for (var index = 0; index < 32; index++) {
    buffer.write(_hexDigits[_random.nextInt(16)]);
  }
  return buffer.toString();
}
