import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/csv_import.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../theme.dart';
import '../../widgets/app_bar.dart';
import '../../widgets/async_view.dart';
import '../../widgets/feedback.dart';
import '../../widgets/guarded.dart';
import '../../widgets/l10n_scope.dart';

/// Personal reading stats, yearly goals and the want-to-read list.
///
/// The app bar names the sub-tab that is showing (stats or want-to-read),
/// since the bottom navigation is icon-only.
class ReadingScreen extends ConsumerStatefulWidget {
  const ReadingScreen({super.key});

  @override
  ConsumerState<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends ConsumerState<ReadingScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  int _titleIndex = 0;

  @override
  void initState() {
    super.initState();
    // Swiping or tapping a sub-tab must rewrite the app bar's title. The
    // controller also ticks during the animation, so only the settled index
    // triggers a rebuild.
    _tabs.addListener(_titleChanged);
  }

  void _titleChanged() {
    if (_tabs.index == _titleIndex || !mounted) return;
    setState(() => _titleIndex = _tabs.index);
  }

  @override
  void dispose() {
    _tabs.removeListener(_titleChanged);
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    return Scaffold(
      appBar: LibraryAppBar(
        title: _titleIndex == 0
            ? l10n.tr('Reading stats')
            : l10n.tr('Want to read'),
        actions: [
          IconButton(
            tooltip: l10n.tr('Import a CSV'),
            icon: const Icon(Icons.upload_file_outlined),
            onPressed: () => context.pushNamed('import-csv'),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: l10n.tr('Stats')),
            Tab(text: l10n.tr('Want to read')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [_StatsTab(), _WantTab()],
      ),
    );
  }
}

class _StatsTab extends ConsumerWidget {
  const _StatsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(readingStatsProvider);
    final goals = ref.watch(readingGoalsProvider);
    return stats.when(
      loading: () => const LoadingView(),
      error: (error, stackTrace) => ErrorView(
        message: describeError(context, error),
        onRetry: () => ref.invalidate(readingStatsProvider),
      ),
      data: (reading) => goals.when(
        loading: () => const LoadingView(),
        error: (error, stackTrace) => ErrorView(
          message: describeError(context, error),
          onRetry: () => ref.invalidate(readingGoalsProvider),
        ),
        data: (goal) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(readingStatsProvider);
            ref.invalidate(readingGoalsProvider);
            try {
              await ref.read(readingStatsProvider.future);
            } on Object {
              // Rendered by the async view.
            }
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              _StatGrid(stats: reading),
              const SizedBox(height: 20),
              _GoalsCard(
                key: ValueKey(
                  '${goal.year}|${goal.targetBooks}|${goal.targetPages}',
                ),
                stats: reading,
                goals: goal,
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

  final ReadingStats stats;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final tiles = <({String label, String value, IconData icon, Color color})>[
      (
        label: l10n.tr('Books read'),
        value: '${stats.booksRead}',
        icon: Icons.menu_book_outlined,
        color: Theme.of(context).colorScheme.primary,
      ),
      (
        label: l10n.tr('Pages read'),
        value: '${stats.pagesRead}',
        icon: Icons.description_outlined,
        color: kEmerald,
      ),
      (
        label: l10n.tr('Average rating'),
        value: stats.avgRating == null ? '—' : '${stats.avgRating}',
        icon: Icons.star_outline,
        color: kAmber,
      ),
      (
        label: l10n.tr('Currently reading'),
        value: '${stats.currentlyReading}',
        icon: Icons.auto_stories_outlined,
        color: kEmerald,
      ),
      (
        label: l10n.tr('DNF'),
        value: '${stats.breakdown('dnf')}',
        icon: Icons.block_outlined,
        color: kViolet,
      ),
      (
        label: l10n.tr('Lost / donated'),
        value: '${stats.lostOrDonated}',
        icon: Icons.help_outline,
        color: kSlate500,
      ),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.55,
      children: [for (final tile in tiles) _StatTile(tile: tile)],
    );
  }
}

typedef _StatSpec = ({String label, String value, IconData icon, Color color});

class _StatTile extends StatelessWidget {
  const _StatTile({required this.tile});

  final _StatSpec tile;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(tile.icon, size: 18, color: tile.color),
                const Spacer(),
                Text(
                  tile.value,
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            Text(
              tile.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: kSlate500),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoalsCard extends ConsumerStatefulWidget {
  const _GoalsCard({super.key, required this.stats, required this.goals});

  final ReadingStats stats;
  final ReadingGoals goals;

  @override
  ConsumerState<_GoalsCard> createState() => _GoalsCardState();
}

class _GoalsCardState extends ConsumerState<_GoalsCard> {
  late final TextEditingController _books;
  late final TextEditingController _pages;
  late int _year;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _books = TextEditingController(
      text: widget.goals.targetBooks == 0 ? '' : '${widget.goals.targetBooks}',
    );
    _pages = TextEditingController(
      text: widget.goals.targetPages == 0 ? '' : '${widget.goals.targetPages}',
    );
    _year = widget.goals.year ?? 0;
  }

  @override
  void dispose() {
    _books.dispose();
    _pages.dispose();
    super.dispose();
  }

  List<int> get _years {
    final thisYear = DateTime.now().year;
    final years = <int>{0, widget.goals.year ?? 0};
    for (var year = thisYear - 2; year <= thisYear + 1; year++) {
      years.add(year);
    }
    final sorted = years.toList()..sort();
    return sorted;
  }

  int _target(TextEditingController controller) =>
      int.tryParse(controller.text.trim()) ?? 0;

  Future<void> _save() async {
    final l10n = context.localized;
    final goals = ReadingGoals(
      year: _year == 0 ? null : _year,
      targetBooks: _target(_books),
      targetPages: _target(_pages),
      progress: <String, dynamic>{
        'books_read': widget.stats.booksRead,
        'pages_read': widget.stats.pagesRead,
      },
    );
    setState(() => _saving = true);
    final saved = await runGuarded<bool>(context, ref, () async {
      await ref.read(repoProvider).saveReadingGoals(goals);
      return true;
    }, successMessage: l10n.tr('Goals saved.'));
    if (mounted) setState(() => _saving = false);
    if (saved == true) ref.invalidate(readingGoalsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final booksTarget = _target(_books);
    final pagesTarget = _target(_pages);
    final bookValue = booksTarget == 0
        ? 0.0
        : (widget.stats.booksRead / booksTarget).clamp(0.0, 1.0);
    final pageValue = pagesTarget == 0
        ? 0.0
        : (widget.stats.pagesRead / pagesTarget).clamp(0.0, 1.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.tr('Reading goals'),
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _year,
              decoration: InputDecoration(labelText: l10n.tr('Year')),
              items: [
                for (final year in _years)
                  DropdownMenuItem(
                    value: year,
                    child: Text(year == 0 ? l10n.tr('Any year') : '$year'),
                  ),
              ],
              onChanged: (value) => setState(() => _year = value ?? 0),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _books,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: l10n.tr('Target books'),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _pages,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: l10n.tr('Target pages'),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _ProgressRow(
              label: l10n.tr('Books'),
              done: widget.stats.booksRead,
              target: booksTarget,
              value: bookValue,
            ),
            const SizedBox(height: 10),
            _ProgressRow(
              label: l10n.tr('Pages'),
              done: widget.stats.pagesRead,
              target: pagesTarget,
              value: pageValue,
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.flag_outlined, size: 18),
                label: Text(l10n.tr('Save goals')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow({
    required this.label,
    required this.done,
    required this.target,
    required this.value,
  });

  final String label;
  final int done;
  final int target;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const Spacer(),
            Text(
              target == 0 ? '$done' : '$done / $target',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: kSlate500),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(minHeight: 8, value: value),
        ),
      ],
    );
  }
}

class _WantTab extends ConsumerWidget {
  const _WantTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.localized;
    final entries = ref.watch(wantListProvider);
    return entries.when(
      loading: () => const LoadingView(),
      error: (error, stackTrace) => ErrorView(
        message: describeError(context, error),
        onRetry: () => ref.invalidate(wantListProvider),
      ),
      data: (items) => RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(wantListProvider);
          try {
            await ref.read(wantListProvider.future);
          } on Object {
            // Rendered by the async view.
          }
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.tr('%(count)s book(s) to look for.', {
                      'count': items.length,
                    }),
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: kSlate500),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => _showAddDialog(context, ref),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(l10n.tr('Add')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (items.isEmpty)
              _EmptyWantList(onAdd: () => _showAddDialog(context, ref))
            else
              for (final entry in items)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.bookmark_border),
                    title: Text(entry.title),
                    subtitle: Text(
                      [
                        if (entry.authors.isNotEmpty) entry.authors,
                        if (entry.isbn != null && entry.isbn!.isNotEmpty)
                          'ISBN ${entry.isbn}',
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: l10n.tr('Remove from want-to-read'),
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _remove(context, ref, entry),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    WantEntry entry,
  ) async {
    final l10n = context.localized;
    final confirmed = await confirmAction(
      context,
      title: l10n.tr('Remove from want-to-read'),
      message: l10n.tr('Remove “%(title)s” from the want-to-read list?', {
        'title': entry.title,
      }),
      confirmLabel: l10n.tr('Remove'),
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    final removed = await runGuarded<bool>(context, ref, () async {
      await ref.read(repoProvider).removeWant(entry.id);
      return true;
    }, successMessage: l10n.tr('Removed from the want-to-read list.'));
    if (removed == true) ref.invalidate(wantListProvider);
  }

  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) async {
    final l10n = context.localized;
    final title = TextEditingController();
    final authors = TextEditingController();
    try {
      final result = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.tr('Add to want-to-read')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: l10n.tr('Title')),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: authors,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(labelText: l10n.tr('Authors')),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.tr('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.tr('Add')),
            ),
          ],
        ),
      );
      final name = title.text.trim();
      if (result != true || name.isEmpty || !context.mounted) return;
      final added = await runGuarded<bool>(context, ref, () async {
        await ref
            .read(repoProvider)
            .addWant(
              WantEntry(
                id: newWantId(),
                title: name,
                authors: authors.text.trim(),
                addedAt: DateTime.now().toUtc().toIso8601String(),
              ),
            );
        return true;
      }, successMessage: l10n.tr('Added to the want-to-read list.'));
      if (added == true) ref.invalidate(wantListProvider);
    } finally {
      title.dispose();
      authors.dispose();
    }
  }
}

class _EmptyWantList extends StatelessWidget {
  const _EmptyWantList({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(
            Icons.bookmark_border,
            size: 56,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.tr('Nothing on your want-to-read list yet.'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: kSlate500),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: Text(l10n.tr('Add a book')),
          ),
        ],
      ),
    );
  }
}
