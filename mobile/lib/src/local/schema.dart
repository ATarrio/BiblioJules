/// The on-device library schema.
///
/// This is deliberately a **copy of the server's schema** (``app/models/``),
/// table for table and column for column, minus ``users`` and ``tokens`` —
/// accounts and sessions only exist when a server is doing the authenticating.
/// Keeping the two identical buys two things:
///
/// * the SQL the server runs ports over one-to-one, so "lent out", "everything
///   under this shelf" and the rest mean exactly the same thing on a phone;
/// * an exported file *is* a BiblioJules database, so it can be dropped into a
///   hosted instance's ``data/`` directory (or imported back off one).
///
/// ``test/schema_parity_test.dart`` fails if the server adds or renames a
/// column without this file following.
library;

/// Bumped whenever the statements below change, so ``onUpgrade`` can migrate
/// an existing library instead of silently running against the wrong schema.
///
/// * 1 — the first release of local mode.
/// * 2 — the shared-library columns: ``sync_id`` and ``updated_at`` on every
///   synced row, and ``sync_tombstones`` for deletions.
/// * 3 — ``reading_goals``: reading objectives move from a side JSON file into
///   the database, so the single-file export carries them and a reinstalled app
///   gets its objectives back.
const int kLibrarySchemaVersion = 3;

/// Every table and index, in creation order.
///
/// Types mirror what SQLAlchemy emits for SQLite, including the deliberate
/// ``NULL``-able columns: a book with no ISBN is perfectly normal, so ``isbn``
/// is ``UNIQUE`` but nullable, and SQLite allows any number of ``NULL``s there.
const List<String> kLibrarySchemaStatements = <String>[
  '''
  CREATE TABLE authors (
    id INTEGER PRIMARY KEY,
    name VARCHAR(255) NOT NULL UNIQUE,
    sync_id VARCHAR(32),
    updated_at DATETIME
  )
  ''',
  'CREATE INDEX ix_authors_name ON authors (name)',
  'CREATE UNIQUE INDEX ix_authors_sync_id ON authors (sync_id)',
  '''
  CREATE TABLE publishers (
    id INTEGER PRIMARY KEY,
    name VARCHAR(255) NOT NULL UNIQUE,
    sync_id VARCHAR(32),
    updated_at DATETIME
  )
  ''',
  'CREATE INDEX ix_publishers_name ON publishers (name)',
  'CREATE UNIQUE INDEX ix_publishers_sync_id ON publishers (sync_id)',
  '''
  CREATE TABLE locations (
    id INTEGER PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    kind VARCHAR(50),
    description TEXT,
    parent_id INTEGER REFERENCES locations (id) ON DELETE CASCADE,
    created_at DATETIME NOT NULL,
    sync_id VARCHAR(32),
    updated_at DATETIME
  )
  ''',
  'CREATE INDEX ix_locations_name ON locations (name)',
  'CREATE INDEX ix_locations_parent_id ON locations (parent_id)',
  'CREATE UNIQUE INDEX ix_locations_sync_id ON locations (sync_id)',
  '''
  CREATE TABLE statuses (
    id INTEGER PRIMARY KEY,
    name VARCHAR(80) NOT NULL UNIQUE,
    slug VARCHAR(80) NOT NULL UNIQUE,
    color VARCHAR(20) NOT NULL,
    icon VARCHAR(16),
    description TEXT,
    sort_order INTEGER NOT NULL,
    is_system BOOLEAN NOT NULL,
    is_default BOOLEAN NOT NULL,
    created_at DATETIME NOT NULL,
    sync_id VARCHAR(32),
    updated_at DATETIME
  )
  ''',
  'CREATE INDEX ix_statuses_name ON statuses (name)',
  'CREATE INDEX ix_statuses_slug ON statuses (slug)',
  'CREATE UNIQUE INDEX ix_statuses_sync_id ON statuses (sync_id)',
  '''
  CREATE TABLE books (
    id INTEGER PRIMARY KEY,
    isbn VARCHAR(20) UNIQUE,
    title VARCHAR(500) NOT NULL,
    subtitle VARCHAR(500),
    publisher_id INTEGER REFERENCES publishers (id) ON DELETE SET NULL,
    published_date VARCHAR(60),
    published_year INTEGER,
    description TEXT,
    page_count INTEGER,
    language VARCHAR(60),
    cover_url VARCHAR(1000),
    cover_type VARCHAR(20),
    read_status VARCHAR(20),
    score FLOAT,
    saga VARCHAR(255),
    saga_number INTEGER,
    location_id INTEGER REFERENCES locations (id) ON DELETE SET NULL,
    status_id INTEGER REFERENCES statuses (id) ON DELETE SET NULL,
    source VARCHAR(40),
    notes TEXT,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    sync_id VARCHAR(32)
  )
  ''',
  'CREATE INDEX ix_books_isbn ON books (isbn)',
  'CREATE INDEX ix_books_title ON books (title)',
  'CREATE INDEX ix_books_publisher_id ON books (publisher_id)',
  'CREATE INDEX ix_books_published_year ON books (published_year)',
  'CREATE INDEX ix_books_location_id ON books (location_id)',
  'CREATE INDEX ix_books_status_id ON books (status_id)',
  'CREATE UNIQUE INDEX ix_books_sync_id ON books (sync_id)',
  '''
  CREATE TABLE book_authors (
    book_id INTEGER NOT NULL REFERENCES books (id) ON DELETE CASCADE,
    author_id INTEGER NOT NULL REFERENCES authors (id) ON DELETE CASCADE,
    PRIMARY KEY (book_id, author_id)
  )
  ''',
  '''
  CREATE TABLE loans (
    id INTEGER PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books (id) ON DELETE CASCADE,
    borrower_name VARCHAR(150) NOT NULL,
    borrower_contact VARCHAR(255),
    lent_at DATE NOT NULL,
    due_at DATE,
    returned_at DATE,
    notes TEXT,
    created_at DATETIME NOT NULL,
    sync_id VARCHAR(32),
    updated_at DATETIME
  )
  ''',
  'CREATE INDEX ix_loans_book_id ON loans (book_id)',
  'CREATE UNIQUE INDEX ix_loans_sync_id ON loans (sync_id)',
  '''
  CREATE TABLE reading_goals (
    id INTEGER PRIMARY KEY,
    user_id INTEGER,
    year INTEGER,
    target_books INTEGER,
    target_pages INTEGER,
    books_done INTEGER,
    pages_done INTEGER
  )
  ''',
  'CREATE INDEX ix_reading_goals_user_id ON reading_goals (user_id)',
  'CREATE INDEX ix_reading_goals_year ON reading_goals (year)',
  '''
  CREATE TABLE sync_tombstones (
    table_name VARCHAR(40) NOT NULL,
    sync_id VARCHAR(32) NOT NULL,
    deleted_at DATETIME NOT NULL,
    PRIMARY KEY (table_name, sync_id)
  )
  ''',
];

/// The tables whose rows carry a ``sync_id`` and an ``updated_at``.
///
/// Mirrors ``SYNCED_TABLES`` in ``app/services/sync.py`` (and
/// ``app/database.py``), and is the list the merge walks.
const List<String> kSyncedTables = <String>[
  'books',
  'authors',
  'publishers',
  'locations',
  'statuses',
  'loans',
];

/// Tables a delete can be remembered for. Loans go with their book, and
/// orphan-pruning is garbage collection rather than a user delete.
const List<String> kTombstoneTables = <String>['books', 'statuses', 'locations'];

/// The column statements that upgrade a version-1 library to version 2.
///
/// SQLite cannot add a ``NOT NULL`` column without a constant default, so both
/// new columns are nullable; every insert fills them. They are also added in
/// the same order the server's migration uses, so an upgraded file and a fresh
/// one look the same to a merge.
const List<String> kSyncMigrationStatements = <String>[
  'ALTER TABLE authors ADD COLUMN sync_id VARCHAR(32)',
  'ALTER TABLE authors ADD COLUMN updated_at DATETIME',
  'ALTER TABLE publishers ADD COLUMN sync_id VARCHAR(32)',
  'ALTER TABLE publishers ADD COLUMN updated_at DATETIME',
  'ALTER TABLE locations ADD COLUMN sync_id VARCHAR(32)',
  'ALTER TABLE locations ADD COLUMN updated_at DATETIME',
  'ALTER TABLE statuses ADD COLUMN sync_id VARCHAR(32)',
  'ALTER TABLE statuses ADD COLUMN updated_at DATETIME',
  'ALTER TABLE books ADD COLUMN sync_id VARCHAR(32)',
  'ALTER TABLE loans ADD COLUMN sync_id VARCHAR(32)',
  'ALTER TABLE loans ADD COLUMN updated_at DATETIME',
  'CREATE UNIQUE INDEX IF NOT EXISTS ix_authors_sync_id ON authors (sync_id)',
  'CREATE UNIQUE INDEX IF NOT EXISTS ix_publishers_sync_id ON publishers (sync_id)',
  'CREATE UNIQUE INDEX IF NOT EXISTS ix_locations_sync_id ON locations (sync_id)',
  'CREATE UNIQUE INDEX IF NOT EXISTS ix_statuses_sync_id ON statuses (sync_id)',
  'CREATE UNIQUE INDEX IF NOT EXISTS ix_books_sync_id ON books (sync_id)',
  'CREATE UNIQUE INDEX IF NOT EXISTS ix_loans_sync_id ON loans (sync_id)',
  '''
  CREATE TABLE IF NOT EXISTS sync_tombstones (
    table_name VARCHAR(40) NOT NULL,
    sync_id VARCHAR(32) NOT NULL,
    deleted_at DATETIME NOT NULL,
    PRIMARY KEY (table_name, sync_id)
  )
  ''',
];

/// The statements that upgrade a version-2 library to version 3.
///
/// Reading objectives used to be a side JSON file; they now live in a table so
/// the single-file export carries them. The table is independent (no foreign
/// keys), so creating it on an existing library is all the migration needs.
const List<String> kGoalsMigrationStatements = <String>[
  '''
  CREATE TABLE IF NOT EXISTS reading_goals (
    id INTEGER PRIMARY KEY,
    user_id INTEGER,
    year INTEGER,
    target_books INTEGER,
    target_pages INTEGER,
    books_done INTEGER,
    pages_done INTEGER
  )
  ''',
  'CREATE INDEX IF NOT EXISTS ix_reading_goals_user_id ON reading_goals (user_id)',
  'CREATE INDEX IF NOT EXISTS ix_reading_goals_year ON reading_goals (year)',
];

/// The system statuses a brand-new library starts with.
///
/// Copied from ``app/services/seed.py``: only the ``slug`` is meaningful to the
/// code (it powers "lent out"/"available" when a book is lent and returned),
/// everything else is yours to rename.
const List<Map<String, Object?>> kDefaultStatuses = <Map<String, Object?>>[
  {
    'slug': 'available',
    'name': 'In library',
    'color': '#16a34a',
    'icon': '📚',
    'sort_order': 10,
    'is_default': true,
  },
  {
    'slug': 'reading',
    'name': 'Reading',
    'color': '#2563eb',
    'icon': '📖',
    'sort_order': 20,
    'is_default': false,
  },
  {
    'slug': 'lent',
    'name': 'Lent out',
    'color': '#d97706',
    'icon': '🤝',
    'sort_order': 30,
    'is_default': false,
  },
  {
    'slug': 'wishlist',
    'name': 'Wishlist',
    'color': '#7c3aed',
    'icon': '⭐',
    'sort_order': 40,
    'is_default': false,
  },
  {
    'slug': 'lost',
    'name': 'Lost',
    'color': '#dc2626',
    'icon': '🕳️',
    'sort_order': 50,
    'is_default': false,
  },
  {
    'slug': 'donated',
    'name': 'Donated',
    'color': '#64748b',
    'icon': '🎁',
    'sort_order': 60,
    'is_default': false,
  },
];

/// The tables this app needs. Used when validating an imported file: a database
/// carrying *more* than this is fine (that is what a file copied off a server
/// looks like — it also has ``users`` and ``tokens``), but anything missing one
/// of these is not a BiblioJules library.
const List<String> kRequiredTables = <String>[
  'authors',
  'publishers',
  'locations',
  'statuses',
  'books',
  'book_authors',
  'loans',
];
