import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/book_fields.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/util.dart';
import '../../theme.dart';
import '../../widgets/app_bar.dart';
import '../../widgets/async_view.dart';
import '../../widgets/book_cover.dart';
import '../../widgets/feedback.dart';
import '../../widgets/guarded.dart';
import '../../widgets/l10n_scope.dart';

/// Everything the catalogue knows about one book, plus the actions that change
/// it.
class BookDetailScreen extends ConsumerWidget {
  const BookDetailScreen({super.key, required this.bookId});

  final int bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.localized;
    final book = ref.watch(bookProvider(bookId));
    final current = book.value;
    return Scaffold(
      appBar: LibraryAppBar(
        title: current?.title ?? l10n.tr('Book'),
        actions: [
          if (current != null) ...[
            IconButton(
              tooltip: l10n.tr('Edit'),
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.pushNamed(
                'book-edit',
                pathParameters: {'id': '$bookId'},
              ),
            ),
            IconButton(
              tooltip: current.isLoaned ? l10n.tr('Return') : l10n.tr('Lend'),
              icon: Icon(
                current.isLoaned ? Icons.assignment_return_outlined : Icons.person_add_alt,
              ),
              onPressed: () => context.pushNamed(
                'book-loan',
                pathParameters: {'id': '$bookId'},
              ),
            ),
          ],
        ],
        extraItems: [
          LibraryAppBarItem('copy-isbn', l10n.tr('Copy ISBN'), Icons.numbers),
          LibraryAppBarItem(
            'delete',
            l10n.tr('Delete book'),
            Icons.delete_outline,
            destructive: true,
          ),
        ],
        onExtraSelected: (value) async {
          if (value == 'copy-isbn') {
            final isbn = current?.isbn;
            if (isbn == null || isbn.isEmpty) {
              showSnack(context, l10n.tr('This book has no ISBN.'), isError: true);
              return;
            }
            await Clipboard.setData(ClipboardData(text: isbn));
            if (context.mounted) showSnack(context, l10n.tr('ISBN copied.'));
            return;
          }
          if (value == 'delete' && current != null) {
            final confirmed = await confirmAction(
              context,
              title: l10n.tr('Delete book'),
              message: l10n.tr(
                'Delete “%(title)s” from the catalogue? Its loan history goes too.',
                {'title': current.title},
              ),
              confirmLabel: l10n.tr('Delete'),
              destructive: true,
            );
            if (!confirmed || !context.mounted) return;
            final deleted = await runGuarded(
              context,
              ref,
              () => ref.read(apiClientProvider).deleteBook(bookId),
            );
            if (deleted == null) return;
            invalidateBooks(ref);
            if (context.mounted) context.pop();
          }
        },
        showSync: false,
      ),
      body: AsyncView<Book>(
        value: book,
        onRetry: () => ref.invalidate(bookProvider(bookId)),
        builder: (book) => _BookBody(book: book),
      ),
    );
  }
}

class _BookBody extends ConsumerWidget {
  const _BookBody({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.localized;
    final loans = ref.watch(bookLoansProvider(book.id));
    final readStatus = readStatusLabel(book.readStatus);
    final coverType = coverTypeLabel(book.coverType);
    final stars = scoreStars(book.score);
    final saga = book.saga == null
        ? null
        : (book.sagaNumber == null ? book.saga! : '${book.saga!} #${book.sagaNumber}');

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookCover(url: book.coverUrl, title: book.title, width: 104, height: 156),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    style: Theme.of(
                      context,
                    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  if (book.subtitle != null && book.subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      book.subtitle!,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: kSlate400),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    book.authorDisplay,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  if (stars.isNotEmpty)
                    Text(
                      stars,
                      style: const TextStyle(
                        color: kAmber,
                        fontSize: 18,
                        letterSpacing: 1.2,
                      ),
                    ),
                  if (book.status != null) ...[
                    const SizedBox(height: 8),
                    _Pill(
                      label: book.status!.name,
                      color: parseHexColor(book.status!.color),
                      icon: Icons.label_outline,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => context.pushNamed(
                  'book-loan',
                  pathParameters: {'id': '${book.id}'},
                ),
                icon: Icon(
                  book.isLoaned ? Icons.assignment_return_outlined : Icons.person_add_alt,
                ),
                label: Text(book.isLoaned ? l10n.tr('Return') : l10n.tr('Lend')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => context.pushNamed(
                  'book-edit',
                  pathParameters: {'id': '${book.id}'},
                ),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(l10n.tr('Edit')),
              ),
            ),
          ],
        ),
        if (book.activeLoan != null) ...[
          const SizedBox(height: 20),
          _LoanCard(loan: book.activeLoan!),
        ],
        const SizedBox(height: 24),
        _Section(
          title: l10n.tr('Details'),
          rows: [
            if (readStatus.isNotEmpty) (l10n.tr('Read status'), l10n.tr(readStatus)),
            if (coverType.isNotEmpty) (l10n.tr('Cover type'), l10n.tr(coverType)),
            if (saga != null) (l10n.tr('Saga'), saga),
            if (book.publishedDate != null && book.publishedDate!.isNotEmpty)
              (l10n.tr('Published'), book.publishedDate!),
            if (book.publisher != null && book.publisher!.isNotEmpty)
              (l10n.tr('Publisher'), book.publisher!),
            if (book.pageCount != null) (l10n.tr('Pages'), '${book.pageCount}'),
            if (book.language != null && book.language!.isNotEmpty)
              (l10n.tr('Language'), book.language!),
            if (book.location != null) (l10n.tr('Location'), book.location!.display),
            if (book.isbn != null && book.isbn!.isNotEmpty) (l10n.tr('ISBN'), book.isbn!),
          ],
        ),
        if (book.description != null && book.description!.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionTitle(l10n.tr('Description')),
          const SizedBox(height: 8),
          Text(book.description!, style: Theme.of(context).textTheme.bodyMedium),
        ],
        if (book.notes != null && book.notes!.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionTitle(l10n.tr('Notes')),
          const SizedBox(height: 8),
          Text(book.notes!, style: Theme.of(context).textTheme.bodyMedium),
        ],
        const SizedBox(height: 24),
        _SectionTitle(l10n.tr('Loan history')),
        const SizedBox(height: 8),
        loans.when(
          data: (items) => items.isEmpty
              ? Text(
                  l10n.tr('Never lent out.'),
                  style: const TextStyle(color: kSlate500),
                )
              : Column(
                  children: [
                    for (final loan in items) _LoanHistoryTile(loan: loan),
                  ],
                ),
          loading: () => const Padding(
            padding: EdgeInsets.all(8),
            child: LinearProgressIndicator(),
          ),
          error: (error, stackTrace) => Text(
            describeError(context, error),
            style: const TextStyle(color: kRed),
          ),
        ),
      ],
    );
  }
}

class _LoanCard extends StatelessWidget {
  const _LoanCard({required this.loan});

  final Loan loan;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final color = loan.isOverdue ? kRed : kEmerald;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person_outline, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  loan.borrowerName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                l10n.tr(loan.isOverdue ? 'Overdue' : 'On loan'),
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            [
              if (loan.lentAt != null)
                '${l10n.tr('Lent on')} ${formatDate(loan.lentAt, l10n.language)}',
              if (loan.dueAt != null)
                '${l10n.tr('Due')} ${formatDate(loan.dueAt, l10n.language)}',
            ].join(' · '),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSlate300),
          ),
          if (loan.borrowerContact != null && loan.borrowerContact!.isNotEmpty)
            Text(
              loan.borrowerContact!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSlate400),
            ),
        ],
      ),
    );
  }
}

class _LoanHistoryTile extends StatelessWidget {
  const _LoanHistoryTile({required this.loan});

  final Loan loan;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            loan.isActive ? Icons.schedule : Icons.check_circle_outline,
            size: 16,
            color: loan.isActive ? kAmber : kSlate500,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${loan.borrowerName} · ${formatDate(loan.lentAt, l10n.language)}'
              '${loan.returnedAt == null ? '' : ' → ${formatDate(loan.returnedAt, l10n.language)}'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Text(
            loan.isActive ? l10n.tr('On loan') : l10n.tr('Returned'),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: kSlate500),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: kSlate500,
        letterSpacing: 1.1,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows});

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(title),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (var index = 0; index < rows.length; index++) ...[
                if (index > 0) const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(
                          rows[index].$1,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: kSlate400),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          rows[index].$2,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
