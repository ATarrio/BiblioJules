/// A book on loan to somebody outside the library.
class Loan {
  const Loan({
    required this.id,
    required this.bookId,
    required this.borrowerName,
    this.borrowerContact,
    this.lentAt,
    this.dueAt,
    this.returnedAt,
    this.isActive = true,
    this.isOverdue = false,
    this.notes,
  });

  final int id;
  final int bookId;
  final String borrowerName;
  final String? borrowerContact;

  /// ISO date strings (``YYYY-MM-DD``).
  final String? lentAt;
  final String? dueAt;
  final String? returnedAt;
  final bool isActive;
  final bool isOverdue;
  final String? notes;

  factory Loan.fromJson(Map<String, dynamic> json) {
    return Loan(
      id: (json['id'] as num).toInt(),
      bookId: (json['book_id'] as num).toInt(),
      borrowerName: (json['borrower_name'] ?? '') as String,
      borrowerContact: json['borrower_contact'] as String?,
      lentAt: json['lent_at'] as String?,
      dueAt: json['due_at'] as String?,
      returnedAt: json['returned_at'] as String?,
      isActive: (json['is_active'] ?? true) as bool,
      isOverdue: (json['is_overdue'] ?? false) as bool,
      notes: json['notes'] as String?,
    );
  }
}

/// An active loan together with the book it belongs to (dashboard shape).
class LoanWithBook {
  const LoanWithBook({required this.loan, this.bookId, this.bookTitle});

  final Loan loan;
  final int? bookId;
  final String? bookTitle;

  factory LoanWithBook.fromJson(Map<String, dynamic> json) {
    final book = json['book'] as Map<String, dynamic>?;
    return LoanWithBook(
      loan: Loan.fromJson(json),
      bookId: (book?['id'] as num?)?.toInt(),
      bookTitle: book?['title'] as String?,
    );
  }
}
