/// Where a local library lives on the device, and what it is called.
///
/// A "local library" is one SQLite file under the app's own documents
/// directory:
///
///     <app documents>/libraries/<slug>.sqlite
///
/// That directory is private to the app, which is what keeps local mode free of
/// any storage permission. Getting a copy *out* (to Downloads, to Drive) is a
/// separate, deliberate step — see [LibraryTransfer].
library;

import '../core/util.dart';

/// The folder that holds every library file.
const String kLibrariesFolder = 'libraries';

/// The name a library gets before the user renames it.
const String kDefaultLibraryName = 'My library';

/// Turn a human name into a filename-safe slug: ``Mi biblioteca`` → ``mi-biblioteca``.
///
/// Mirrors the server's ``library.slugify`` (via [slugify]) so the same name
/// yields the same file name everywhere. An empty or entirely-punctuation name
/// falls back to a sensible default rather than producing a nameless file.
String librarySlug(String name) => slugify(name, fallback: 'my-library');

/// The file name for a library called [name].
String libraryFileName(String name) => '${librarySlug(name)}.sqlite';
