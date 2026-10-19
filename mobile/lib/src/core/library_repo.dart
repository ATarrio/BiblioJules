/// Where a screen's data comes from.
///
/// The app can run against two very different back ends:
///
/// * [ApiClient] — a hosted BiblioJules server, reached over HTTP.
/// * ``LocalRepo`` — a SQLite file on the phone itself, which needs no network
///   and no account.
///
/// Both expose this one interface and both hand back the same model objects, so
/// screens never learn which mode they are in. Anything that only makes sense
/// against a server (signing in, choosing a server address) deliberately lives
/// on [ApiClient] rather than here.
library;

import 'models/models.dart';

/// The catalogue operations every back end must provide.
///
/// Signatures are shared verbatim with the JSON API's routes: the parameter
/// names map onto the query string, and the return types onto the response
/// bodies. ``LocalRepo`` must produce byte-for-byte equivalent objects.
abstract interface class LibraryRepo {
  // --- books -------------------------------------------------------------- //
  Future<List<Book>> listBooks({
    String? search,
    int? statusId,
    int? locationId,
    int? authorId,
    int? publisherId,
    String? loaned,
    String? saga,
    String? readStatus,
    String sort = 'recent',
    String? direction,
  });

  Future<Book> getBook(int id);

  /// ``null`` when no book carries [isbn] (used to spot duplicates).
  Future<Book?> findByIsbn(String isbn);

  Future<List<Loan>> bookLoans(int bookId);

  Future<Book> createBook(Map<String, dynamic> payload);

  Future<Book> updateBook(int id, Map<String, dynamic> payload);

  Future<bool> deleteBook(int id);

  // --- loans -------------------------------------------------------------- //
  Future<Loan> lendBook(
    int bookId, {
    required String borrowerName,
    String? borrowerContact,
    String? lentAt,
    String? dueAt,
    String? notes,
    bool markStatus = true,
  });

  Future<void> returnBook(
    int bookId, {
    String? returnedAt,
    bool restoreStatus = true,
  });

  // --- locations ---------------------------------------------------------- //
  Future<List<Location>> listLocations();

  Future<Location> createLocation({
    required String name,
    int? parentId,
    String? kind,
    String? description,
  });

  Future<Location> updateLocation(
    int id, {
    required String name,
    int? parentId,
    String? kind,
    String? description,
  });

  Future<bool> deleteLocation(int id);

  // --- statuses ----------------------------------------------------------- //
  Future<List<Status>> listStatuses();

  Future<Status> createStatus({
    required String name,
    String color = '#64748b',
    String? icon,
    String? description,
  });

  Future<Status> updateStatus(
    int id, {
    required String name,
    String color = '#64748b',
    String? icon,
    String? description,
  });

  Future<bool> deleteStatus(int id);

  // --- reference data ----------------------------------------------------- //
  Future<List<RefItem>> listAuthors();

  Future<List<RefItem>> listPublishers();

  Future<List<String>> listSagas();

  // --- aggregates & lookup ------------------------------------------------ //
  Future<DashboardData> dashboard();

  Future<Stats> stats();

  /// Online metadata for one ISBN (Open Library / Google Books).
  Future<SearchResult?> lookupIsbn(String isbn);

  Future<List<SearchResult>> searchBooks(String query, {int limit = 12});
}
