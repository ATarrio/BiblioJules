import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api_exception.dart';
import '../core/book_fields.dart';
import '../core/models/models.dart';
import '../core/providers.dart';
import '../theme.dart';
import '../widgets/app_bar.dart';
import '../widgets/book_cover.dart';
import '../widgets/feedback.dart';
import '../widgets/l10n_scope.dart';

/// Fill the catalogue from the outside world: an ISBN barcode, a typed ISBN, or
/// a title/author search across Open Library and Google Books.
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final _isbn = TextEditingController();
  final _search = TextEditingController();

  bool _busy = false;
  SearchResult? _lookup;
  String? _lookupMessage;
  List<SearchResult> _results = const [];
  String? _resultsQuery;
  String? _resultsMessage;

  @override
  void dispose() {
    _isbn.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final code = await context.push<String>('/scan');
    if (code == null || code.isEmpty || !mounted) return;
    setState(() => _isbn.text = code);
    await _lookupIsbn();
  }

  Future<void> _lookupIsbn() async {
    final isbn = normalizeIsbn(_isbn.text);
    if (isbn.isEmpty) {
      showSnack(context, context.localized.tr('Enter an ISBN first.'), isError: true);
      return;
    }
    setState(() {
      _busy = true;
      _lookup = null;
      _lookupMessage = null;
      _isbn.text = isbn;
    });
    final api = ref.read(apiClientProvider);
    try {
      final existing = await api.findByIsbn(isbn);
      final result = await api.lookupIsbn(isbn);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _lookup = result;
        _lookupMessage = result == null
            ? context.localized.tr('No catalogue entry found for that ISBN.')
            : (existing == null
                  ? null
                  : context.localized.tr(
                      'Already in your library as “%(title)s”.',
                      {'title': existing.title},
                    ));
      });
    } on ApiAuthException catch (error) {
      await ref.read(sessionProvider.notifier).handleRejectedToken(error.message);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _lookupMessage = error.message;
      });
    }
  }

  Future<void> _searchOnline() async {
    final query = _search.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _resultsMessage = null;
      _resultsQuery = query;
    });
    try {
      final results = await ref.read(apiClientProvider).searchBooks(query);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _results = results;
        if (results.isEmpty) {
          _resultsMessage = context.localized.tr(
            'No results for “%(query)s”. Try a different spelling.',
            {'query': query},
          );
        }
      });
    } on ApiAuthException catch (error) {
      await ref.read(sessionProvider.notifier).handleRejectedToken(error.message);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _resultsMessage = error.message;
      });
    }
  }

  /// Hand a result to the book form; warn first if the ISBN is already ours.
  Future<void> _add(SearchResult result) async {
    final isbn = result.isbn;
    if (isbn != null && isbn.isNotEmpty) {
      try {
        final existing = await ref.read(apiClientProvider).findByIsbn(isbn);
        if (existing != null && mounted) {
          final open = await confirmAction(
            context,
            title: context.localized.tr('Already in your library'),
            message: context.localized.tr(
              '“%(title)s” already has this ISBN. Open it instead?',
              {'title': existing.title},
            ),
            confirmLabel: context.localized.tr('Open'),
          );
          if (open && mounted) {
            context.pushNamed('book', pathParameters: {'id': '${existing.id}'});
          }
          return;
        }
      } on ApiException {
        // Fall through: the form will report any real problem on save.
      }
    }
    if (!mounted) return;
    await context.pushNamed('book-new', extra: result);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    return Scaffold(
      appBar: LibraryAppBar(title: l10n.tr('Discover')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.tr('Add by ISBN'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _isbn,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _lookupIsbn(),
                    decoration: InputDecoration(
                      labelText: l10n.tr('ISBN'),
                      prefixIcon: const Icon(Icons.numbers),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _lookupIsbn,
                          icon: const Icon(Icons.cloud_download_outlined, size: 18),
                          label: Text(l10n.tr('Look up')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _scan,
                          icon: const Icon(Icons.qr_code_scanner, size: 18),
                          label: Text(l10n.tr('Scan')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_lookupMessage != null) ...[
            const SizedBox(height: 12),
            _Notice(message: _lookupMessage!),
          ],
          if (_lookup != null) ...[
            const SizedBox(height: 12),
            _ResultCard(
              result: _lookup!,
              actionLabel: l10n.tr('Add to library'),
              onAction: () => _add(_lookup!),
            ),
          ],
          const SizedBox(height: 28),
          Text(
            l10n.tr('Search online catalogues').toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: kSlate500,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _searchOnline(),
            decoration: InputDecoration(
              hintText: l10n.tr('Title, author…'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                tooltip: l10n.tr('Search'),
                onPressed: _busy ? null : _searchOnline,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            if (_resultsMessage != null) _Notice(message: _resultsMessage!),
            if (_results.isNotEmpty && _resultsQuery != null) ...[
              Text(
                l10n.tn(
                  '%(count)s result for “%(query)s”',
                  '%(count)s results for “%(query)s”',
                  _results.length,
                  {'query': _resultsQuery},
                ),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSlate400),
              ),
              const SizedBox(height: 8),
              for (final result in _results)
                _ResultCard(
                  result: result,
                  actionLabel: l10n.tr('Add'),
                  onAction: () => _add(result),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kAmber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kAmber.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18, color: kAmber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.result,
    required this.actionLabel,
    required this.onAction,
  });

  final SearchResult result;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookCover(url: result.coverUrl, title: result.title, width: 52, height: 78),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    result.authorsDisplay,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kSlate400, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (result.publisher != null) result.publisher!,
                      if (result.publishedDate != null) result.publishedDate!,
                      if (result.isbn != null) result.isbn!,
                    ].join(' · '),
                    style: const TextStyle(color: kSlate500, fontSize: 11),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      onPressed: onAction,
                      icon: const Icon(Icons.add, size: 16),
                      label: Text(actionLabel),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
