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
        data: (objectives) => RefreshIndicator(
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
              // One read-only card per saved objective: year + progress/total.
              if (objectives.isEmpty)
                _EmptyGoals()
              else
                for (final objective in objectives)
                  _GoalCard(
                    goal: objective,
                    remove: (year) async {
                      await runGuarded<bool>(
                        context,
                        ref,
                        () async {
                          await ref.read(repoProvider).removeReadingGoal(year);
                          return true;
                        },
                        successMessage: context.localized.tr(
                          'Objective removed.',
                        ),
                      );
                      ref.invalidate(readingGoalsProvider);
                    },
                  ),
              const SizedBox(height: 20),
              // The editor stays last so saved objectives are seen first.
              _GoalsEditor(stats: reading),
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

/// A saved objective, shown read-only: its year and progress against target.
class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.goal, required this.remove});

  final ReadingGoals goal;
  final Future<void> Function(int year) remove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final booksDone = goal.booksDone;
    final pagesDone = goal.pagesDone;
    final booksTarget = goal.targetBooks;
    final pagesTarget = goal.targetPages;
    final bookValue = booksTarget == 0
        ? 0.0
        : (booksDone / booksTarget).clamp(0.0, 1.0);
    final pageValue = pagesTarget == 0
        ? 0.0
        : (pagesDone / pagesTarget).clamp(0.0, 1.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  goal.year == null
                      ? l10n.tr('Any year')
                      : '${goal.year}',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                TextButton(
                  onPressed: () => remove(goal.year ?? 0),
                  child: const Text("🗑️"),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (booksTarget > 0)
              _ProgressRow(
                label: l10n.tr('Books'),
                done: booksDone,
                target: booksTarget,
                value: bookValue,
              ),
            if (pagesTarget > 0) ...[
              const SizedBox(height: 10),
              _ProgressRow(
                label: l10n.tr('Pages'),
                done: pagesDone,
                target: pagesTarget,
                value: pageValue,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyGoals extends StatelessWidget {
  const _EmptyGoals();

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        l10n.tr('No objectives yet. Set one below.'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: kSlate500),
      ),
    );
  }
}

/// The form that captures one objective (year + targets) and saves it.
class _GoalsEditor extends ConsumerStatefulWidget {
  const _GoalsEditor({required this.stats});

  final ReadingStats stats;

  @override
  ConsumerState<_GoalsEditor> createState() => _GoalsEditorState();
}

class _GoalsEditorState extends ConsumerState<_GoalsEditor> {
  late final TextEditingController _books;
  late final TextEditingController _pages;
  late int _year;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _books = TextEditingController();
    _pages = TextEditingController();
    _year = 0;
  }

  @override
  void dispose() {
    _books.dispose();
    _pages.dispose();
    super.dispose();
  }

  List<int> get _years {
    final thisYear = DateTime.now().year;
    // Only offer the current year and future years.
    final years = <int>{0};
    for (var year = thisYear; year <= thisYear + 2; year++) {
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

class _WantTab extends ConsumerStatefulWidget {
  const _WantTab();

  @override
  ConsumerState<_WantTab> createState() => _WantTabState();
}

class _WantTabState extends ConsumerState<_WantTab> {
  final Set<String> _selectedIds = {};

  void _toggleSelection(String id, bool? selected) {
    setState(() {
      if (selected == true) {
        _selectedIds.add(id);
      } else {
        _selectedIds.remove(id);
      }
    });
  }

  void _selectAll(List<WantEntry> items) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(items.map((e) => e.id));
    });
  }

  void _clearSelection() {
    setState(() => _selectedIds.clear());
  }

  bool _isSelected(WantEntry entry) => _selectedIds.contains(entry.id);

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
    if (removed == true) {
      _selectedIds.remove(entry.id);
      ref.invalidate(wantListProvider);
    }
  }

  Future<void> _moveToCatalog(BuildContext context, WidgetRef ref,
      WantEntry entry) async {
    final l10n = context.localized;
    final confirmed = await confirmAction(
      context,
      title: l10n.tr('Move to catalog'),
      message: l10n.tr(
        'Move “%(title)s” to your catalog with “to read” status?',
        {'title': entry.title},
      ),
      confirmLabel: l10n.tr('Move'),
    );
    if (!confirmed || !context.mounted) return;

    // Open the add book form pre-filled with this entry's data. The entry only
    // leaves the want-to-read list once the book is actually saved, so backing
    // out of the form (or a failed save) leaves it where it was.
    final added = await context.pushNamed<bool>('book-new', extra: entry);
    if (added != true || !context.mounted) return;

    await runGuarded<bool>(context, ref, () async {
      await ref.read(repoProvider).removeWant(entry.id);
      return true;
    });
    _selectedIds.remove(entry.id);
    ref.invalidate(wantListProvider);
  }

  Future<void> _moveSelectionToCatalog(BuildContext context, WidgetRef ref,
      List<WantEntry> items) async {
    final l10n = context.localized;
    final selected = items.where((e) => _selectedIds.contains(e.id)).toList();
    if (selected.isEmpty) return;

    final confirmed = await confirmAction(
      context,
      title: l10n.tr('Move selection to catalog'),
      message: l10n.tr(
        'Move %(count)s book(s) to your catalog with “to read” status?',
        {'count': selected.length},
      ),
      confirmLabel: l10n.tr('Move'),
    );
    if (!confirmed || !context.mounted) return;

    final errors = <String>[];
    for (final entry in selected) {
      try {
        await ref.read(repoProvider).createBook(<String, dynamic>{
          'isbn': entry.isbn,
          'title': entry.title,
          'authors': entry.authors.isNotEmpty ? entry.authors : null,
          'publisher': entry.publisher,
          'read_status': 'to_read',
          'source': 'want_list_import',
        });
        await ref.read(repoProvider).removeWant(entry.id);
      } on Object catch (_) {
        errors.add(entry.title);
      }
    }
    if (context.mounted) {
      setState(() => _selectedIds.clear());
      ref.invalidate(wantListProvider);
      if (errors.isNotEmpty) {
        showSnack(
          context,
          l10n.tr('Some books could not be moved: %(titles)s', {
            'titles': errors.join(', '),
          }),
          isError: true,
        );
      } else {
        showSnack(context, l10n.tr('Moved %(count)s book(s) to catalog.', {
          'count': selected.length,
        }));
      }
    }
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

  @override
  Widget build(BuildContext context) {
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
                if (_selectedIds.isNotEmpty)
                  FilledButton.icon(
                    onPressed: () =>
                        _moveSelectionToCatalog(context, ref, items),
                    icon: const Icon(Icons.login, size: 18),
                    label: Text(
                      l10n.tr('Move %(count)s selected', {
                        'count': _selectedIds.length,
                      }),
                    ),
                  )
                else
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_selectedIds.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.tr(
                                '%(count)s book(s) selected.',
                                {'count': _selectedIds.length},
                              ),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          TextButton(
                            onPressed: () => _clearSelection(),
                            child: Text(l10n.tr('Clear selection')),
                          ),
                          TextButton(
                            onPressed: () => _selectAll(items),
                            child: Text(l10n.tr('Select all')),
                          ),
                        ],
                      ),
                    ),
                  ...items.map((entry) => Card(
                    child: ListTile(
                      leading: Checkbox(
                        value: _isSelected(entry),
                        onChanged: (v) => _toggleSelection(entry.id, v),
                      ),
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
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: l10n.tr('Move to catalog'),
                            icon: const Icon(Icons.login, size: 18),
                            onPressed: () =>
                                _moveToCatalog(context, ref, entry),
                          ),
                          IconButton(
                            tooltip: l10n.tr('Remove from want-to-read'),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _remove(context, ref, entry),
                          ),
                        ],
                      ),
                    ),
                  )),
                ],
              ),
          ],
        ),
      ),
    );
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
