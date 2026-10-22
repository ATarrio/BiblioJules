import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../theme.dart';
import '../../widgets/app_bar.dart';
import '../../widgets/book_cover.dart';
import '../../widgets/feedback.dart';
import '../../widgets/form_fields.dart';
import '../../widgets/l10n_scope.dart';
import '../../widgets/picker_sheet.dart';

/// Add a book, or edit one that is already in the catalogue.
///
/// Also the landing place for the Discover tab and the barcode scanner, both of
/// which hand over what they found through [initialIsbn] or [initialData].
class BookFormScreen extends ConsumerStatefulWidget {
  const BookFormScreen({super.key, this.bookId, this.initialIsbn, this.initialData});

  final int? bookId;
  final String? initialIsbn;

  /// Metadata from an online lookup, used to prefill a brand-new book.
  final SearchResult? initialData;

  @override
  ConsumerState<BookFormScreen> createState() => _BookFormScreenState();
}

class _BookFormScreenState extends ConsumerState<BookFormScreen> {
  final _formKey = GlobalKey<FormState>();

  final _title = TextEditingController();
  final _subtitle = TextEditingController();
  final _authors = TextEditingController();
  final _isbn = TextEditingController();
  final _publisher = TextEditingController();
  final _publishedDate = TextEditingController();
  final _pageCount = TextEditingController();
  final _language = TextEditingController();
  final _coverUrl = TextEditingController();
  final _saga = TextEditingController();
  final _notes = TextEditingController();
  final _description = TextEditingController();

  String? _coverType;
  String? _readStatus;
  double? _score;
  int? _sagaNumber;
  int? _locationId;
  int? _statusId;
  String? _source;

  bool _loading = false;
  bool _saving = false;
  bool _lookingUp = false;

  bool get _isEdit => widget.bookId != null;

  @override
  void initState() {
    super.initState();
    final data = widget.initialData;
    if (widget.initialIsbn != null) _isbn.text = widget.initialIsbn!;
    if (data != null) {
      _title.text = data.title;
      _authors.text = data.authors.join(', ');
      _publisher.text = data.publisher ?? '';
      _publishedDate.text = data.publishedDate ?? '';
      _pageCount.text = data.pageCount?.toString() ?? '';
      _language.text = data.language ?? '';
      _coverUrl.text = data.coverUrl ?? '';
      _description.text = data.description ?? '';
      _source = data.source;
      if (data.isbn != null && _isbn.text.isEmpty) _isbn.text = data.isbn!;
    }
    if (_isEdit) {
      _load();
    } else {
      // A new book starts on the library's default shelf.
      final statuses = ref.read(statusesProvider).value;
      if (statuses != null) _statusId = Status.defaultOf(statuses)?.id;
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _title,
      _subtitle,
      _authors,
      _isbn,
      _publisher,
      _publishedDate,
      _pageCount,
      _language,
      _coverUrl,
      _saga,
      _notes,
      _description,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final book = await ref.read(repoProvider).getBook(widget.bookId!);
      if (!mounted) return;
      setState(() {
        _title.text = book.title;
        _subtitle.text = book.subtitle ?? '';
        _authors.text = book.authors.join(', ');
        _isbn.text = book.isbn ?? '';
        _publisher.text = book.publisher ?? '';
        _publishedDate.text = book.publishedDate ?? '';
        _pageCount.text = book.pageCount?.toString() ?? '';
        _language.text = book.language ?? '';
        _coverUrl.text = book.coverUrl ?? '';
        _saga.text = book.saga ?? '';
        _notes.text = book.notes ?? '';
        _description.text = book.description ?? '';
        _coverType = book.coverType;
        _readStatus = book.readStatus;
        _score = book.score;
        _sagaNumber = book.sagaNumber;
        _locationId = book.locationId;
        _statusId = book.statusId;
        _source = book.source;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showSnack(context, error.message, isError: true);
    }
  }

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Map<String, dynamic> _payload() {
    final payload = <String, dynamic>{
      'isbn': _blankToNull(_isbn.text),
      'title': _title.text.trim(),
      'subtitle': _blankToNull(_subtitle.text),
      'authors': _authors.text.trim(),
      'publisher': _blankToNull(_publisher.text),
      'published_date': _blankToNull(_publishedDate.text),
      'description': _blankToNull(_description.text),
      'page_count': int.tryParse(_pageCount.text.trim()),
      'language': _blankToNull(_language.text),
      'cover_url': _blankToNull(_coverUrl.text),
      'cover_type': _coverType,
      'read_status': _readStatus,
      'score': _score,
      'saga': _blankToNull(_saga.text),
      'saga_number': _sagaNumber,
      'location_id': _locationId,
      'status_id': _statusId,
      'notes': _blankToNull(_notes.text),
    };
    if (_source != null) payload['source'] = _source;
    return payload;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    final api = ref.read(repoProvider);
    try {
      if (_isEdit) {
        await api.updateBook(widget.bookId!, _payload());
      } else {
        await api.createBook(_payload());
      }
      invalidateBooks(ref);
      if (!mounted) return;
      showSnack(context, context.localized.tr(_isEdit ? 'Book saved.' : 'Book added.'));
      context.pop();
    } on ApiAuthException catch (error) {
      await ref.read(sessionProvider.notifier).handleRejectedToken(error.message);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, error.message, isError: true);
    }
  }

  /// Fill in what we can from Open Library / Google Books.
  Future<void> _lookup() async {
    final isbn = _isbn.text.trim();
    if (isbn.isEmpty) {
      showSnack(context, context.localized.tr('Enter an ISBN first.'), isError: true);
      return;
    }
    setState(() => _lookingUp = true);
    final api = ref.read(repoProvider);
    try {
      final existing = await api.findByIsbn(isbn);
      if (existing != null && existing.id != widget.bookId) {
        if (!mounted) return;
        setState(() => _lookingUp = false);
        final open = await confirmAction(
          context,
          title: context.localized.tr('Already in your library'),
          message: context.localized.tr(
            '“%(title)s” already has this ISBN. Open it?',
            {'title': existing.title},
          ),
          confirmLabel: context.localized.tr('Open'),
        );
        if (open && mounted) {
          context.pop();
          context.pushNamed('book', pathParameters: {'id': '${existing.id}'});
        }
        return;
      }
      final result = await api.lookupIsbn(isbn);
      if (!mounted) return;
      setState(() => _lookingUp = false);
      if (result == null) {
        showSnack(
          context,
          context.localized.tr('No catalogue entry found for that ISBN.'),
          isError: true,
        );
        return;
      }
      setState(() {
        if (_title.text.trim().isEmpty) _title.text = result.title;
        if (_authors.text.trim().isEmpty) _authors.text = result.authors.join(', ');
        if (_publisher.text.trim().isEmpty) _publisher.text = result.publisher ?? '';
        if (_publishedDate.text.trim().isEmpty) {
          _publishedDate.text = result.publishedDate ?? '';
        }
        if (_pageCount.text.trim().isEmpty) {
          _pageCount.text = result.pageCount?.toString() ?? '';
        }
        if (_language.text.trim().isEmpty) _language.text = result.language ?? '';
        if (_coverUrl.text.trim().isEmpty) _coverUrl.text = result.coverUrl ?? '';
        if (_description.text.trim().isEmpty) {
          _description.text = result.description ?? '';
        }
        _source = result.source ?? _source;
      });
      showSnack(context, context.localized.tr('Filled in the missing fields.'));
    } on ApiAuthException catch (error) {
      await ref.read(sessionProvider.notifier).handleRejectedToken(error.message);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _lookingUp = false);
      showSnack(context, error.message, isError: true);
    }
  }

  Future<void> _scan() async {
    final code = await context.push<String>('/scan');
    if (code == null || code.isEmpty || !mounted) return;
    setState(() => _isbn.text = code);
    await _lookup();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final locations = ref.watch(locationsProvider);
    final statuses = ref.watch(statusesProvider);
    final publishers = ref.watch(publishersProvider);

    if (_loading) {
      return Scaffold(
        appBar: LibraryAppBar(title: l10n.tr('Edit book'), showSync: false),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: LibraryAppBar(
        title: _isEdit ? l10n.tr('Edit book') : l10n.tr('Add book'),
        showSync: false,
        actions: [
          IconButton(
            tooltip: l10n.tr('Save'),
            icon: const Icon(Icons.check),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          children: [
            // ISBN field at top with prominent scan button
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _isbn,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l10n.tr('ISBN'),
                      prefixIcon: const Icon(Icons.numbers, size: 20),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: l10n.tr('Scan a barcode'),
                  child: FilledButton.icon(
                    onPressed: _scan,
                    icon: const Icon(Icons.qr_code_scanner, size: 24),
                    label: const Text('Scan'),
                  ),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: l10n.tr('Look up online'),
                  child: TextButton.icon(
                    onPressed: _lookingUp ? null : _lookup,
                    icon: _lookingUp
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_download_outlined),
                    label: Text(_lookingUp ? '' : l10n.tr('Look up')),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Remaining fields
            if (locations.value != null && statuses.value != null)
              const SizedBox.shrink(),
            TextFormField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l10n.tr('Title')),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? l10n.tr('A title is required.')
                  : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _subtitle,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l10n.tr('Subtitle')),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _authors,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: l10n.tr('Authors'),
                helperText: l10n.tr('Separate several authors with commas.'),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _publisher,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(labelText: l10n.tr('Publisher')),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: l10n.tr('Choose an existing publisher'),
                  onPressed: () async {
                    final items = publishers.value ?? const <RefItem>[];
                    final picked = await showPickerSheet<String>(
                      context,
                      title: l10n.tr('Publisher'),
                      selected: _blankToNull(_publisher.text),
                      options: [
                        for (final item in items) PickerOption(item.name, item.name),
                      ],
                    );
                    if (picked?.value != null) {
                      setState(() => _publisher.text = picked!.value!);
                    }
                  },
                  icon: const Icon(Icons.list_alt),
                ),
              ],
            ),
            const SizedBox(height: 14),
            PublishedDateField(
              controller: _publishedDate,
              onPicked: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _pageCount,
                    keyboardType: TextInputType.number,
                    inputFormatters: const [DigitsOnlyFormatter()],
                    decoration: InputDecoration(labelText: l10n.tr('Pages')),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: TextFormField(
                    controller: _language,
                    decoration: InputDecoration(labelText: l10n.tr('Language')),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            CoverTypeChips(
              value: _coverType,
              onChanged: (value) => setState(() => _coverType = value),
            ),
            const SizedBox(height: 20),
            ReadStatusChips(
              value: _readStatus,
              onChanged: (value) => setState(() => _readStatus = value),
            ),
            const SizedBox(height: 16),
            ScoreField(
              value: _score,
              onChanged: (value) => setState(() => _score = value),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Consumer(builder: (context, ref, child) {
                    final sagasAsync = ref.watch(sagasProvider);
                    final suggestions = sagasAsync.when(
                      data: (list) => list,
                      loading: () => const <String>[],
                      error: (_, _) => const <String>[],
                    );
                    return RawAutocomplete<String>(
                      textEditingController: _saga,
                      focusNode: FocusNode(),
                      optionsBuilder: (TextEditingValue textEditingValue) {
                        if (textEditingValue.text == '') return suggestions;
                        final input = textEditingValue.text.toLowerCase();
                        return suggestions.where((s) => s.toLowerCase().contains(input));
                      },
                      onSelected: (String selection) {
                        setState(() => _saga.text = selection);
                      },
                      fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                        return TextFormField(
                          controller: _saga,
                          focusNode: focusNode,
                          textCapitalization: TextCapitalization.words,
                          onFieldSubmitted: (value) => onFieldSubmitted(),
                          decoration: InputDecoration(labelText: l10n.tr('Saga')),
                        );
                      },
                      displayStringForOption: (String option) => option,
                      optionsViewBuilder: (context, onSelected, options) {
                        return Align(
                          alignment: Alignment.topLeft,
                          child: Material(
                            elevation: 4.0,
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              width: 250,
                              constraints: const BoxConstraints(maxHeight: 250),
                              child: ListView.builder(
                                shrinkWrap: true,
                                itemCount: options.length,
                                itemBuilder: (context, index) {
                                  final option = options.elementAt(index);
                                  return ListTile(
                                    dense: true,
                                    title: Text(option),
                                    onTap: () => onSelected(option),
                                  );
                                },
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  }),
                ),
                const SizedBox(width: 14),
                NumberStepper(
                  label: l10n.tr('Number'),
                  value: _sagaNumber,
                  onChanged: (value) => setState(() => _sagaNumber = value),
                ),
              ],
            ),
            const SizedBox(height: 20),
            PickerField(
              label: l10n.tr('Status'),
              icon: Icons.label_outline,
              clearable: true,
              value: _statusName(statuses.value, _statusId),
              onClear: () => setState(() => _statusId = null),
              onTap: () async {
                final items = statuses.value ?? const <Status>[];
                final picked = await showPickerSheet<int>(
                  context,
                  title: l10n.tr('Status'),
                  selected: _statusId,
                  options: [
                    for (final status in items)
                      PickerOption(
                        status.id,
                        status.name,
                        color: parseHexColor(status.color),
                      ),
                  ],
                );
                if (picked != null) setState(() => _statusId = picked.value);
              },
            ),
            const SizedBox(height: 14),
            PickerField(
              label: l10n.tr('Location'),
              icon: Icons.place_outlined,
              clearable: true,
              value: _locationName(locations.value, _locationId),
              onClear: () => setState(() => _locationId = null),
              onTap: () async {
                final items = locations.value ?? const <Location>[];
                final picked = await showPickerSheet<int>(
                  context,
                  title: l10n.tr('Location'),
                  selected: _locationId,
                  options: [
                    for (final location in items)
                      PickerOption(location.id, location.display),
                  ],
                );
                if (picked != null) setState(() => _locationId = picked.value);
              },
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BookCover(url: _coverUrl.text, title: _title.text, width: 56, height: 84),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _coverUrl,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(labelText: l10n.tr('Cover URL')),
                    onChanged: (value) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _description,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l10n.tr('Description')),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _notes,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l10n.tr('Notes')),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 18),
              label: Text(l10n.tr('Save')),
            ),
          ],
        ),
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
}
