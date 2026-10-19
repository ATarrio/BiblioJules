import 'package:flutter/material.dart';

import '../core/book_fields.dart';
import '../core/models/models.dart';
import '../theme.dart';
import 'book_cover.dart';
import 'l10n_scope.dart';

/// One catalogue row: cover, title, authors and the badges that matter at a
/// glance (reading status, score, saga, shelf, loan).
class BookTile extends StatelessWidget {
  const BookTile({super.key, required this.book, this.onTap, this.trailing});

  final Book book;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final readStatus = readStatusLabel(book.readStatus);
    final stars = scoreStars(book.score);
    final saga = book.saga == null
        ? null
        : (book.sagaNumber == null ? book.saga! : '${book.saga!} #${book.sagaNumber}');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookCover(url: book.coverUrl, title: book.title, width: 48, height: 72),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    book.authorDisplay,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: kSlate400),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (book.status != null)
                        _Badge(
                          label: book.status!.name,
                          color: parseHexColor(book.status!.color),
                        ),
                      if (readStatus.isNotEmpty)
                        _Badge(label: l10n.tr(readStatus), color: kSlate400),
                      if (stars.isNotEmpty) _Badge(label: stars, color: kAmber),
                      if (saga != null) _Badge(label: saga, color: kViolet),
                      if (book.location != null)
                        _Badge(
                          label: book.location!.display,
                          color: kSlate400,
                          icon: Icons.place_outlined,
                        ),
                      if (book.isLoaned)
                        _Badge(
                          label: l10n.tr(
                            book.activeLoan!.isOverdue ? 'Overdue' : 'On loan',
                          ),
                          color: book.activeLoan!.isOverdue ? kRed : kEmerald,
                          icon: Icons.person_outline,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
