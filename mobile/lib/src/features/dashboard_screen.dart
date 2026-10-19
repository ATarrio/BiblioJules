import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models/models.dart';
import '../core/providers.dart';
import '../core/util.dart';
import '../theme.dart';
import '../widgets/app_bar.dart';
import '../widgets/async_view.dart';
import '../widgets/book_tile.dart';
import '../widgets/feedback.dart';
import '../widgets/l10n_scope.dart';

/// Counters, shelves breakdown, recent additions and who has what.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.localized;
    final dashboard = ref.watch(dashboardProvider);
    return Scaffold(
      appBar: LibraryAppBar(title: l10n.tr('Dashboard')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(dashboardProvider);
          try {
            await ref.read(dashboardProvider.future);
          } on Object {
            // Rendered below.
          }
        },
        child: dashboard.when(
          data: (data) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              _StatGrid(stats: data.stats),
              const SizedBox(height: 24),
              if (data.statusCounts.isNotEmpty) ...[
                _SectionTitle(l10n.tr('By status')),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      for (final row in data.statusCounts)
                        _StatusCountRow(entry: row, total: data.stats.total),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
              if (data.activeLoans.isNotEmpty) ...[
                _SectionTitle(l10n.tr('Books currently lent out')),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      for (final entry in data.activeLoans)
                        ListTile(
                          leading: Icon(
                            Icons.person_outline,
                            color: entry.loan.isOverdue ? kRed : kEmerald,
                          ),
                          title: Text(entry.bookTitle ?? ''),
                          subtitle: Text(
                            [
                              entry.loan.borrowerName,
                              if (entry.loan.dueAt != null)
                                '${l10n.tr('Due')} ${formatDate(entry.loan.dueAt, l10n.language)}',
                            ].join(' · '),
                          ),
                          trailing: entry.loan.isOverdue
                              ? Text(
                                  l10n.tr('Overdue'),
                                  style: const TextStyle(color: kRed),
                                )
                              : null,
                          onTap: entry.bookId == null
                              ? null
                              : () => context.pushNamed(
                                  'book',
                                  pathParameters: {'id': '${entry.bookId}'},
                                ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
              _SectionTitle(l10n.tr('Recently added')),
              const SizedBox(height: 8),
              if (data.recent.isEmpty)
                Text(l10n.tr('No books yet.'), style: const TextStyle(color: kSlate500))
              else
                Card(
                  child: Column(
                    children: [
                      for (var index = 0; index < data.recent.length; index++) ...[
                        if (index > 0) const Divider(height: 1),
                        BookTile(
                          book: data.recent[index],
                          onTap: () => context.pushNamed(
                            'book',
                            pathParameters: {'id': '${data.recent[index].id}'},
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
          loading: () => const LoadingView(),
          error: (error, stackTrace) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.5,
                child: ErrorView(
                  message: describeError(context, error),
                  onRetry: () => ref.invalidate(dashboardProvider),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.stats});

  final Stats stats;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final items = <(String, String, IconData, Color)>[
      (l10n.tr('Books'), '${stats.total}', Icons.menu_book_outlined,
          Theme.of(context).colorScheme.primary),
      (l10n.tr('Authors'), '${stats.authors}', Icons.person_outline, kViolet),
      (l10n.tr('Publishers'), '${stats.publishers}', Icons.business_outlined, kSlate400),
      (l10n.tr('On loan'), '${stats.loans}', Icons.assignment_return_outlined, kEmerald),
      (l10n.tr('Wishlist'), '${stats.wishlist}', Icons.star_border, kAmber),
    ];
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final item in items)
          SizedBox(
            width: (MediaQuery.of(context).size.width - 44) / 2,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              ),
              child: Row(
                children: [
                  Icon(item.$3, color: item.$4, size: 22),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.$2,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        item.$1,
                        style: const TextStyle(color: kSlate400, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _StatusCountRow extends StatelessWidget {
  const _StatusCountRow({required this.entry, required this.total});

  final StatusCount entry;
  final int total;

  @override
  Widget build(BuildContext context) {
    final color = parseHexColor(entry.status.color);
    final fraction = total == 0 ? 0.0 : entry.count / total;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.status.name, style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 5,
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHigh,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text('${entry.count}', style: const TextStyle(fontWeight: FontWeight.w600)),
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
