import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/util.dart';
import '../../theme.dart';
import '../../widgets/app_bar.dart';
import '../../widgets/book_cover.dart';
import '../../widgets/feedback.dart';
import '../../widgets/l10n_scope.dart';

/// Lending a book out, or taking it back.
class BookLoanScreen extends ConsumerStatefulWidget {
  const BookLoanScreen({super.key, required this.bookId});

  final int bookId;

  @override
  ConsumerState<BookLoanScreen> createState() => _BookLoanScreenState();
}

class _BookLoanScreenState extends ConsumerState<BookLoanScreen> {
  final _borrower = TextEditingController();
  final _contact = TextEditingController();
  final _notes = TextEditingController();
  DateTime _lentAt = DateTime.now();
  DateTime? _dueAt;
  bool _markStatus = true;
  bool _restoreStatus = true;
  bool _busy = false;

  @override
  void dispose() {
    _borrower.dispose();
    _contact.dispose();
    _notes.dispose();
    super.dispose();
  }

  String _iso(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  Future<void> _lend(Book book) async {
    if (_borrower.text.trim().isEmpty) {
      showSnack(context, context.localized.tr('A borrower name is required'), isError: true);
      return;
    }
    final message = context.localized.tr('Loan recorded.');
    setState(() => _busy = true);
    try {
      await ref
          .read(repoProvider)
          .lendBook(
            book.id,
            borrowerName: _borrower.text.trim(),
            borrowerContact: _blankToNull(_contact.text),
            lentAt: _iso(_lentAt),
            dueAt: _dueAt == null ? null : _iso(_dueAt!),
            notes: _blankToNull(_notes.text),
            markStatus: _markStatus,
          );
      _afterWrite(message);
    } on ApiAuthException catch (error) {
      await ref.read(sessionProvider.notifier).handleRejectedToken(error.message);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, error.message, isError: true);
    }
  }

  Future<void> _return(Book book) async {
    final message = context.localized.tr('Book returned.');
    setState(() => _busy = true);
    try {
      await ref
          .read(repoProvider)
          .returnBook(book.id, restoreStatus: _restoreStatus);
      _afterWrite(message);
    } on ApiAuthException catch (error) {
      await ref.read(sessionProvider.notifier).handleRejectedToken(error.message);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, error.message, isError: true);
    }
  }

  void _afterWrite(String message) {
    invalidateBooks(ref);
    ref.invalidate(bookLoansProvider(widget.bookId));
    if (!mounted) return;
    showSnack(context, message);
    context.pop();
  }

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final book = ref.watch(bookProvider(widget.bookId));
    return Scaffold(
      appBar: LibraryAppBar(
        title: book.value?.isLoaned ?? false ? l10n.tr('Return') : l10n.tr('Lend'),
        showSync: false,
      ),
      body: book.when(
        data: (book) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          children: [
            Row(
              children: [
                BookCover(url: book.coverUrl, title: book.title, width: 44, height: 66),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        style: Theme.of(
                          context,
                        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        book.authorDisplay,
                        style: const TextStyle(color: kSlate400, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (book.activeLoan != null)
              _returnForm(context, book.activeLoan!)
            else
              _lendForm(context),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(describeError(context, error), textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }

  Widget _lendForm(BuildContext context) {
    final l10n = context.localized;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _borrower,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: l10n.tr('Borrower'),
            prefixIcon: const Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _contact,
          decoration: InputDecoration(
            labelText: l10n.tr('Contact'),
            hintText: l10n.tr('Phone, email…'),
            prefixIcon: const Icon(Icons.contact_mail_outlined),
          ),
        ),
        const SizedBox(height: 14),
        _DateField(
          label: l10n.tr('Lent on'),
          value: _iso(_lentAt),
          onChanged: (value) {
            if (value != null) setState(() => _lentAt = value);
          },
          allowClear: false,
        ),
        const SizedBox(height: 14),
        _DateField(
          label: l10n.tr('Due'),
          value: _dueAt == null ? null : _iso(_dueAt!),
          onChanged: (value) => setState(() => _dueAt = value),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _notes,
          maxLines: 2,
          decoration: InputDecoration(labelText: l10n.tr('Notes')),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _markStatus,
          onChanged: (value) => setState(() => _markStatus = value),
          title: Text(l10n.tr('Mark the book as \'Lent out\'')),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : () => _lend(bookOrThrow()),
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.person_add_alt, size: 18),
          label: Text(l10n.tr('Lend this book')),
        ),
      ],
    );
  }

  Widget _returnForm(BuildContext context, Loan loan) {
    final l10n = context.localized;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.person_outline, size: 18, color: kEmerald),
                    const SizedBox(width: 8),
                    Text(
                      loan.borrowerName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  [
                    if (loan.lentAt != null)
                      '${l10n.tr('Lent on')} ${formatDate(loan.lentAt, l10n.language)}',
                    if (loan.dueAt != null)
                      '${l10n.tr('Due')} ${formatDate(loan.dueAt, l10n.language)}',
                  ].join(' · '),
                  style: const TextStyle(color: kSlate300, fontSize: 12),
                ),
                if (loan.notes != null && loan.notes!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(loan.notes!, style: const TextStyle(fontSize: 12)),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _restoreStatus,
          onChanged: (value) => setState(() => _restoreStatus = value),
          title: Text(l10n.tr('Mark as available')),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : () => _return(bookOrThrow()),
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.assignment_return_outlined, size: 18),
          label: Text(l10n.tr('Mark returned')),
        ),
      ],
    );
  }

  /// The book is re-read from the cached provider; by the time a form is on
  /// screen it has loaded.
  Book bookOrThrow() => ref.read(bookProvider(widget.bookId)).requireValue;
}

/// A date field with a picker and an optional "no date" state.
class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.allowClear = true,
  });

  final String label;
  final String? value;
  final ValueChanged<DateTime?> onChanged;
  final bool allowClear;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: DateTime.tryParse(value ?? '') ?? now,
          firstDate: DateTime(now.year - 20),
          lastDate: DateTime(now.year + 20),
          helpText: label,
        );
        if (picked != null) onChanged(picked);
      },
      borderRadius: BorderRadius.circular(10),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.event_outlined),
          suffixIcon: value != null && allowClear
              ? IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: l10n.tr('Clear'),
                  onPressed: () => onChanged(null),
                )
              : const Icon(Icons.calendar_month),
        ),
        child: Text(
          value ?? l10n.tr('Not set'),
          style: TextStyle(color: value == null ? kSlate500 : null),
        ),
      ),
    );
  }
}
