import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models/models.dart';
import '../core/providers.dart';
import '../theme.dart';
import '../widgets/app_bar.dart';
import '../widgets/async_view.dart';
import '../widgets/book_tile.dart';
import '../widgets/feedback.dart';
import '../widgets/form_fields.dart';
import '../widgets/l10n_scope.dart';
import '../widgets/picker_sheet.dart';

/// The whole collection, with the web app's search, filters and ordering.
class CatalogScreen extends ConsumerStatefulWidget {
  const CatalogScreen({super.key});

  @override
  ConsumerState<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends ConsumerState<CatalogScreen> {
  late final TextEditingController _search;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: ref.read(catalogQueryProvider).search);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final controller = ref.read(catalogQueryProvider.notifier);
      final trimmed = value.trim();
      if (ref.read(catalogQueryProvider).search == trimmed) return;
      controller.update((query) => query.copyWith(search: trimmed));
    });
  }

  Future<void> _refresh() async {
    ref.invalidate(booksProvider);
    try {
      await ref.read(booksProvider.future);
    } on Object {
      // The error is rendered by the list itself.
    }
  }

  Future<void> _openFilters() async {
    final current = ref.read(catalogQueryProvider);
    final result = await showModalBottomSheet<CatalogQuery>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      builder: (context) => _FilterSheet(initial: current),
    );
    if (result != null) {
      ref.read(catalogQueryProvider.notifier).update((_) => result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final query = ref.watch(catalogQueryProvider);
    final books = ref.watch(booksProvider);
    return Scaffold(
      appBar: LibraryAppBar(
        title: l10n.tr('Catalog'),
        actions: [
          IconButton(
            tooltip: l10n.tr('Filters'),
            onPressed: _openFilters,
            icon: Badge.count(
              count: query.filterCount,
              isLabelVisible: query.filterCount > 0,
              child: const Icon(Icons.filter_list),
            ),
          ),
          _SortButton(query: query),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(58),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _search,
              builder: (context, value, child) => TextField(
                controller: _search,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: l10n.tr('Search title, author, publisher, ISBN…'),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  suffixIcon: value.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: l10n.tr('Clear'),
                          onPressed: () {
                            _search.clear();
                            ref
                                .read(catalogQueryProvider.notifier)
                                .update((query) => query.copyWith(search: ''));
                          },
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.pushNamed('book-new'),
        icon: const Icon(Icons.add),
        label: Text(l10n.tr('Add book')),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: books.when(
          data: (items) => items.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.5,
                      child: EmptyState(
                        message: query.hasFilters
                            ? l10n.tr('No books match those filters.')
                            : l10n.tr('No books yet. Add your first one!'),
                        icon: query.hasFilters ? Icons.filter_alt_off_outlined : Icons.menu_book_outlined,
                        action: query.hasFilters
                            ? TextButton(
                                onPressed: () => ref
                                    .read(catalogQueryProvider.notifier)
                                    .reset(),
                                child: Text(l10n.tr('Clear filters')),
                              )
                            : null,
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    _CountLine(count: items.length),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: items.length,
                        separatorBuilder: (context, index) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final book = items[index];
                          return BookTile(
                            book: book,
                            onTap: () => context.pushNamed(
                              'book',
                              pathParameters: {'id': '${book.id}'},
                            ),
                          );
                        },
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
                  onRetry: () => ref.invalidate(booksProvider),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CountLine extends StatelessWidget {
  const _CountLine({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          l10n.tn('%d book', '%d books', count),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSlate400),
        ),
      ),
    );
  }
}

class _SortButton extends ConsumerWidget {
  const _SortButton({required this.query});

  final CatalogQuery query;

  static const _options = <(String, String, bool)>[
    ('recent', 'Recently added', true),
    ('title', 'Title', false),
    ('author', 'Author', false),
    ('saga', 'Saga', false),
    ('year', 'Year', true),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.localized;
    final active = _options.firstWhere(
      (option) => option.$1 == query.sort,
      orElse: () => _options.first,
    );
    final descending = query.direction == null
        ? active.$3
        : query.direction == 'desc';
    return PopupMenuButton<String>(
      tooltip: l10n.tr('Sort'),
      icon: const Icon(Icons.sort),
      onSelected: (key) => ref.read(catalogQueryProvider.notifier).setSort(key),
      itemBuilder: (context) => [
        for (final option in _options)
          PopupMenuItem(
            value: option.$1,
            child: Row(
              children: [
                Icon(
                  option.$1 == query.sort ? Icons.check : Icons.sort,
                  size: 18,
                  color: option.$1 == query.sort ? kBrand : kSlate500,
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(l10n.tr(option.$2))),
                if (option.$1 == query.sort)
                  Icon(
                    descending ? Icons.arrow_downward : Icons.arrow_upward,
                    size: 16,
                    color: kSlate400,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The filter sheet: a draft copy of the query that is applied on Apply.
class _FilterSheet extends ConsumerStatefulWidget {
  const _FilterSheet({required this.initial});

  final CatalogQuery initial;

  @override
  ConsumerState<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends ConsumerState<_FilterSheet> {
  late CatalogQuery _draft = widget.initial;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final statuses = ref.watch(statusesProvider);
    final locations = ref.watch(locationsProvider);
    final sagas = ref.watch(sagasProvider);
    final authors = ref.watch(authorsProvider);
    final publishers = ref.watch(publishersProvider);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text(l10n.tr('Filters'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          PickerField(
            label: l10n.tr('Status'),
            icon: Icons.label_outline,
            clearable: true,
            value: _statusName(statuses.value, _draft.statusId),
            onClear: () => setState(() => _draft = _draft.copyWith(clearStatus: true)),
            onTap: () async {
              final items = statuses.value ?? const <Status>[];
              final picked = await showPickerSheet<int>(
                context,
                title: l10n.tr('Status'),
                selected: _draft.statusId,
                options: [
                  for (final status in items)
                    PickerOption(
                      status.id,
                      status.name,
                      color: parseHexColor(status.color),
                    ),
                ],
              );
              if (picked != null) {
                setState(
                  () => _draft = picked.value == null
                      ? _draft.copyWith(clearStatus: true)
                      : _draft.copyWith(statusId: picked.value),
                );
              }
            },
          ),
          const SizedBox(height: 12),
          PickerField(
            label: l10n.tr('Location'),
            icon: Icons.place_outlined,
            clearable: true,
            value: _locationName(locations.value, _draft.locationId),
            onClear: () => setState(() => _draft = _draft.copyWith(clearLocation: true)),
            onTap: () async {
              final items = locations.value ?? const <Location>[];
              final picked = await showPickerSheet<int>(
                context,
                title: l10n.tr('Location'),
                selected: _draft.locationId,
                options: [
                  for (final location in items)
                    PickerOption(location.id, location.display),
                ],
              );
              if (picked != null) {
                setState(
                  () => _draft = picked.value == null
                      ? _draft.copyWith(clearLocation: true)
                      : _draft.copyWith(locationId: picked.value),
                );
              }
            },
          ),
          const SizedBox(height: 12),
          PickerField(
            label: l10n.tr('Saga'),
            icon: Icons.auto_stories_outlined,
            clearable: true,
            value: _draft.saga.isEmpty ? null : _draft.saga,
            onClear: () => setState(() => _draft = _draft.copyWith(saga: '')),
            onTap: () async {
              final items = sagas.value ?? const <String>[];
              final picked = await showPickerSheet<String>(
                context,
                title: l10n.tr('Saga'),
                selected: _draft.saga.isEmpty ? null : _draft.saga,
                options: [for (final saga in items) PickerOption(saga, saga)],
                emptyMessage: l10n.tr('No sagas yet.'),
              );
              if (picked != null) {
                setState(() => _draft = _draft.copyWith(saga: picked.value ?? ''));
              }
            },
          ),
          const SizedBox(height: 12),
          PickerField(
            label: l10n.tr('Author'),
            icon: Icons.person_outline,
            clearable: true,
            value: _refName(authors.value, _draft.authorId),
            onClear: () => setState(() => _draft = _draft.copyWith(clearAuthor: true)),
            onTap: () async {
              final items = authors.value ?? const <RefItem>[];
              final picked = await showPickerSheet<int>(
                context,
                title: l10n.tr('Author'),
                selected: _draft.authorId,
                options: [for (final item in items) PickerOption(item.id, item.name)],
              );
              if (picked != null) {
                setState(
                  () => _draft = picked.value == null
                      ? _draft.copyWith(clearAuthor: true)
                      : _draft.copyWith(authorId: picked.value),
                );
              }
            },
          ),
          const SizedBox(height: 12),
          PickerField(
            label: l10n.tr('Publisher'),
            icon: Icons.business_outlined,
            clearable: true,
            value: _refName(publishers.value, _draft.publisherId),
            onClear: () => setState(() => _draft = _draft.copyWith(clearPublisher: true)),
            onTap: () async {
              final items = publishers.value ?? const <RefItem>[];
              final picked = await showPickerSheet<int>(
                context,
                title: l10n.tr('Publisher'),
                selected: _draft.publisherId,
                options: [for (final item in items) PickerOption(item.id, item.name)],
              );
              if (picked != null) {
                setState(
                  () => _draft = picked.value == null
                      ? _draft.copyWith(clearPublisher: true)
                      : _draft.copyWith(publisherId: picked.value),
                );
              }
            },
          ),
          const SizedBox(height: 20),
          ReadStatusChips(
            value: _draft.readStatus,
            onChanged: (value) => setState(
              () => _draft = value == null
                  ? _draft.copyWith(clearReadStatus: true)
                  : _draft.copyWith(readStatus: value),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _draft.loaned,
            onChanged: (value) => setState(() => _draft = _draft.copyWith(loaned: value)),
            title: Text(l10n.tr('On loan only')),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(
                    () => _draft = CatalogQuery(
                      sort: _draft.sort,
                      direction: _draft.direction,
                    ),
                  ),
                  child: Text(l10n.tr('Clear filters')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_draft),
                  child: Text(l10n.tr('Apply')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String? _statusName(List<Status>? statuses, int? id) {
    if (id == null || statuses == null) return null;
    for (final status in statuses) {
      if (status.id == id) return status.name;
    }
    return null;
  }

  String? _locationName(List<Location>? locations, int? id) {
    if (id == null || locations == null) return null;
    for (final location in locations) {
      if (location.id == id) return location.display;
    }
    return null;
  }

  String? _refName(List<RefItem>? items, int? id) {
    if (id == null || items == null) return null;
    for (final item in items) {
      if (item.id == id) return item.name;
    }
    return null;
  }
}
