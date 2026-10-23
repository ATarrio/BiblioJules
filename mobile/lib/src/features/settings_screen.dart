import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api_client.dart';
import '../core/l10n.dart';
import '../core/prefs.dart';
import '../core/providers.dart';
import '../local/library_files.dart';
import '../local/sync.dart';
import '../theme.dart';
import '../widgets/app_bar.dart';
import '../widgets/feedback.dart';
import '../widgets/guarded.dart';
import '../widgets/l10n_scope.dart';

/// Which library the app reads, the account behind it, language, and a way out.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _server;
  bool _testing = false;
  bool _switching = false;
  /// A local-library action (export or import) is in flight: both buttons lock.
  bool _busy = false;
  /// …and which of the two it is, so the spinner lands on the right button.
  bool _exporting = false;
  /// The shared library: the folder's URI and name, and whether a sync runs at
  /// start-up. Held in state (as well as in the preferences) so the row redraws
  /// the moment the user picks a folder.
  String? _syncFolderUri;
  String? _syncFolderName;
  bool _syncOnStart = false;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: ref.read(sessionProvider).baseUrl);
    final prefs = ref.read(prefsProvider);
    _syncFolderUri = prefs.syncFolderUri;
    _syncFolderName = prefs.syncFolderName;
    _syncOnStart = prefs.syncOnStart;
    if (_syncFolderUri != null && _syncFolderName == null) {
      // Stored by a version that only kept the URI: ask Android what it is.
      ref.read(sharedFolderProvider).nameOf(_syncFolderUri!).then((name) {
        if (mounted && name != null) setState(() => _syncFolderName = name);
      });
    }
  }

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  // --- server mode -------------------------------------------------------- //

  Future<void> _saveServer() async {
    final session = ref.read(sessionProvider.notifier);
    final before = ref.read(sessionProvider).baseUrl;
    await session.changeServer(_server.text);
    final after = ref.read(sessionProvider).baseUrl;
    if (!mounted) return;
    if (after == before) {
      showSnack(context, context.localized.tr('That is already the address in use.'));
      return;
    }
    showSnack(context, context.localized.tr('Server address saved. Sign in to continue.'));
  }

  Future<void> _testConnection() async {
    final l10n = context.localized;
    final typed = normalizeBaseUrl(_server.text);
    if (!isValidBaseUrl(typed)) {
      showSnack(context, l10n.tr('Enter the address of your library server.'), isError: true);
      return;
    }
    setState(() => _testing = true);
    try {
      // Test the address in the field, not the one currently in use: changing
      // the field and pressing "Test" must not silently test the old server.
      // No token: this only checks that the typed server answers, and a
      // token issued by the current server must never be sent to another one.
      final probe = ApiClient(baseUrl: typed)
        ..setLanguage(ref.read(prefsProvider).effectiveLanguage);
      await runGuarded(context, ref, () async {
        await probe.ping();
        return true;
      }, successMessage: l10n.tr('Connected.'));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  // --- local mode --------------------------------------------------------- //

  /// Move between the library on this device and one on a server.
  ///
  /// Neither direction throws anything away: the local file stays on disk, and
  /// a server token stays in the keystore, so switching back is instant.
  Future<void> _switchMode(LibraryMode mode) async {
    final l10n = context.localized;
    final session = ref.read(sessionProvider);
    if (mode == LibraryMode.local && session.isLocal) return;
    if (mode == LibraryMode.server && !session.isLocal) return;

    setState(() => _switching = true);
    try {
      if (mode == LibraryMode.local) {
        final name = await promptForText(
          context,
          title: l10n.tr('Library on this phone'),
          message: l10n.tr(
            'Name your library. The name also becomes its file name when you export it.',
          ),
          initial: ref.read(prefsProvider).localLibraryName ?? kDefaultLibraryName,
          label: l10n.tr('Library name'),
          icon: Icons.local_library_outlined,
          confirmLabel: l10n.tr('Use this library'),
        );
        if (name == null) return;
        final ok = await ref.read(sessionProvider.notifier).useLocalLibrary(name);
        if (!ok && mounted) {
          showSnack(
            context,
            l10n.tr(ref.read(sessionProvider).error ?? 'That library could not be opened.'),
            isError: true,
          );
        }
        return;
      }

      final signedIn = ref.read(sessionProvider).token != null;
      final confirmed = await confirmAction(
        context,
        title: l10n.tr('Use a server instead?'),
        message: signedIn
            ? l10n.tr(
                'The library on this phone stays on the device. You will go back to the server you were signed in to.',
              )
            : l10n.tr(
                'The library on this phone stays on the device. You will be asked to sign in.',
              ),
        confirmLabel: l10n.tr('Use the server'),
      );
      if (!confirmed) return;
      await ref.read(sessionProvider.notifier).useServerLibrary();
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _renameLocal() async {
    final l10n = context.localized;
    final name = await promptForText(
      context,
      title: l10n.tr('Rename library'),
      message: l10n.tr('Renaming moves the file, and keeps everything in it.'),
      initial: ref.read(sessionProvider).localLibraryName ?? kDefaultLibraryName,
      label: l10n.tr('Library name'),
      icon: Icons.drive_file_rename_outline,
      confirmLabel: l10n.tr('Rename'),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final ok = await ref.read(sessionProvider.notifier).renameLocalLibrary(name);
    if (!mounted) return;
    showSnack(
      context,
      ok
          ? l10n.tr('Library renamed.')
          : l10n.tr(ref.read(sessionProvider).error ?? 'That library could not be opened.'),
      isError: !ok,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final session = ref.watch(sessionProvider);
    final language = ref.watch(languageProvider);
    final colorTheme = ref.watch(colorThemeProvider);
    return Scaffold(
      appBar: LibraryAppBar(title: l10n.tr('Settings'), showSync: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _Section(title: l10n.tr('Where is your library?')),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<LibraryMode>(
              segments: [
                ButtonSegment(
                  value: LibraryMode.local,
                  icon: const Icon(Icons.phone_android, size: 18),
                  label: Text(l10n.tr('This phone')),
                ),
                ButtonSegment(
                  value: LibraryMode.server,
                  icon: const Icon(Icons.dns_outlined, size: 18),
                  label: Text(l10n.tr('A server')),
                ),
              ],
              selected: {session.isLocal ? LibraryMode.local : LibraryMode.server},
              onSelectionChanged: _switching
                  ? null
                  : (selection) => _switchMode(selection.first),
            ),
          ),
          const SizedBox(height: 16),
          if (session.isLocal) ..._localSection(l10n, session) else ..._serverSection(l10n),

          if (!session.isLocal) ...[
            _Section(title: l10n.tr('Account')),
            if (session.user != null)
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(session.user!.shown),
                      subtitle: Text(
                        session.user!.displayName == null
                            ? session.user!.username
                            : '@${session.user!.username}',
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.badge_outlined),
                      title: Text(l10n.tr('Role')),
                      trailing: Text(
                        session.user!.isAdmin
                            ? l10n.tr('Administrator')
                            : l10n.tr('Member'),
                        style: TextStyle(
                          color: session.user!.isAdmin
                              ? Theme.of(context).colorScheme.primary
                              : kSlate400,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final confirmed = await confirmAction(
                  context,
                  title: l10n.tr('Sign out'),
                  message: l10n.tr(
                    'Sign out of %(name)s on this device?',
                    {'name': session.user?.shown ?? kAppName},
                  ),
                  confirmLabel: l10n.tr('Sign out'),
                  destructive: true,
                );
                if (!confirmed) return;
                await ref.read(sessionProvider.notifier).signOut();
                if (context.mounted) context.goNamed('login');
              },
              icon: const Icon(Icons.logout, size: 18),
              label: Text(l10n.tr('Sign out')),
            ),
          ],

          _Section(title: l10n.tr('Language')),
          Card(
            child: Column(
              children: [
                for (final option in kSupportedLanguages)
                  ListTile(
                    leading: Icon(
                      option.code == language ? Icons.check_circle : Icons.translate,
                      color: option.code == language
                          ? Theme.of(context).colorScheme.primary
                          : kSlate500,
                    ),
                    title: Text(option.label),
                    subtitle: option.code == kDefaultLanguage
                        ? null
                        : Text(option.code),
                    onTap: () => ref.read(languageProvider.notifier).set(option.code),
                  ),
              ],
            ),
          ),

          _Section(title: l10n.tr('Theme')),
          Card(
            child: Column(
              children: [
                for (final option in kThemes)
                  ListTile(
                    leading: _ThemeDot(theme: option, selected: option.slug == colorTheme),
                    title: Text(l10n.tr(option.label)),
                    onTap: () => ref.read(colorThemeProvider.notifier).set(option.slug),
                  ),
              ],
            ),
          ),

          _Section(title: l10n.tr('About')),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(l10n.tr('About %(app)s', {'app': kAppName})),
                  subtitle: Text('${l10n.tr('Version')} $kAppVersion'),
                  trailing: const Icon(Icons.chevron_right, color: kSlate500),
                  onTap: () => context.pushNamed('about'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _serverSection(L10n l10n) {
    return [
      TextField(
        controller: _server,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: l10n.tr('Backend URL'),
          hintText: 'https://library.example.com',
          prefixIcon: const Icon(Icons.dns_outlined),
          helperText: l10n.tr('Point the app at the computer hosting your library.'),
          helperMaxLines: 2,
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _saveServer,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(l10n.tr('Save')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _testing ? null : _testConnection,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering, size: 18),
              label: Text(l10n.tr('Test connection')),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        l10n.tr('Changing this signs you out, because accounts live on each server.'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSlate500),
      ),
    ];
  }

  List<Widget> _localSection(L10n l10n, SessionState session) {
    final name = session.localLibraryName ?? kDefaultLibraryName;
    return [
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.local_library_outlined),
              title: Text(name),
              subtitle: Text(l10n.tr('Stored on this device only')),
              trailing: TextButton(
                onPressed: _renameLocal,
                child: Text(l10n.tr('Rename')),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Text(
        l10n.tr(
          'This catalogue lives in a file on the phone: no account and no network. Export it to keep a copy or to move it to a server.',
        ),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSlate500),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _busy ? null : _exportLibrary,
              icon: _exporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.ios_share, size: 18),
              label: Text(l10n.tr('Export…')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _importLibrary,
              icon: const Icon(Icons.file_download_outlined, size: 18),
              label: Text(l10n.tr('Import…')),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        l10n.tr(
          'Export writes a single .sqlite file wherever you choose — your phone, a Drive folder, a USB stick. Import reads one back and replaces this library.',
        ),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSlate500),
      ),
      _Section(title: l10n.tr('Shared library')),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.folder_shared_outlined),
              title: Text(
                _syncFolderName ?? l10n.tr('No folder chosen yet'),
              ),
              subtitle: Text(
                _syncFolderUri == null
                    ? l10n.tr(
                        'Pick a folder in Drive — or anywhere else that reaches your other devices — to share this library.',
                      )
                    : l10n.tr('Snapshots of this library are exchanged through it.'),
              ),
              trailing: TextButton(
                onPressed: _busy || _syncing ? null : _chooseSyncFolder,
                child: Text(l10n.tr('Choose folder…')),
              ),
            ),
            if (_syncFolderUri != null) ...[
              const Divider(height: 1),
              SwitchListTile(
                value: _syncOnStart,
                onChanged: _busy || _syncing ? null : _setSyncOnStart,
                secondary: const Icon(Icons.schedule_outlined),
                title: Text(l10n.tr('Sync when the app starts')),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.sync),
                title: Text(l10n.tr('Sync now')),
                trailing: _syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right, color: kSlate500),
                onTap: _busy || _syncing ? null : _syncNow,
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 8),
      Text(
        l10n.tr(
          'Every device keeps its own copy of the library. Each sync merges the snapshot in this folder and writes a fresh one, so Google Drive (or Syncthing, or a USB stick) never sees a live database.',
        ),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kSlate500),
      ),
    ];
  }

  /// Write a snapshot of the library wherever the user points the picker.
  Future<void> _exportLibrary() async {
    final l10n = context.localized;
    setState(() {
      _busy = true;
      _exporting = true;
    });
    try {
      final saved = await ref.read(libraryTransferProvider).exportLibrary();
      if (!mounted || saved == null) return;
      showSnack(
        context,
        l10n.tr('Library exported as %(name)s.', {'name': saved}),
      );
    } on Object catch (error) {
      if (mounted) showSnack(context, describeError(context, error), isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _exporting = false;
        });
      }
    }
  }

  /// Take a file the user picked and make it this device's library.
  ///
  /// Nothing is merged: the confirmation says so plainly, because a mis-tap here
  /// would otherwise be a nasty surprise.
  Future<void> _importLibrary() async {
    final l10n = context.localized;
    final current = ref.read(sessionProvider).localLibraryName ?? kDefaultLibraryName;
    final confirmed = await confirmAction(
      context,
      title: l10n.tr('Import a library?'),
      message: l10n.tr(
        'Everything currently in “%(name)s” is thrown away and replaced by the file you pick. This cannot be undone.',
        {'name': current},
      ),
      confirmLabel: l10n.tr('Pick a file'),
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    try {
      final name = await ref.read(libraryTransferProvider).importLibrary();
      if (!mounted || name == null) return;
      // The whole catalogue changed under the screens that are still open.
      refreshEverything(ref);
      showSnack(context, l10n.tr('Library imported.'));
    } on Object catch (error) {
      if (mounted) showSnack(context, describeError(context, error), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- the shared library ------------------------------------------------ //

  /// Ask for the folder snapshots are exchanged through, and remember it.
  Future<void> _chooseSyncFolder() async {
    final l10n = context.localized;
    setState(() => _busy = true);
    try {
      final choice = await ref.read(sharedFolderProvider).choose();
      if (!mounted || choice == null) return;
      await ref.read(prefsProvider).setSyncFolder(choice.uri, name: choice.name);
      // The sync provider caches the URI it was built with.
      ref.invalidate(librarySyncProvider);
      if (!mounted) return;
      setState(() {
        _syncFolderUri = choice.uri;
        _syncFolderName = choice.name.isEmpty ? null : choice.name;
      });
      showSnack(context, l10n.tr('Shared folder saved.'));
    } on Object catch (error) {
      if (mounted) showSnack(context, describeError(context, error), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setSyncOnStart(bool value) async {
    await ref.read(prefsProvider).setSyncOnStart(value);
    if (mounted) setState(() => _syncOnStart = value);
  }

  /// Merge whatever the folder holds, then publish what is new here.
  Future<void> _syncNow() async {
    final l10n = context.localized;
    final sync = ref.read(librarySyncProvider);
    if (sync == null) {
      showSnack(context, l10n.tr('Choose a shared folder in Settings first.'), isError: true);
      return;
    }
    setState(() => _syncing = true);
    try {
      final result = await sync.run();
      // Books, shelfs and loans may all have moved under the open screens.
      refreshEverything(ref);
      if (!mounted) return;
      showSnack(context, _describeSync(l10n, result));
    } on Object catch (error) {
      if (mounted) showSnack(context, describeError(context, error), isError: true);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// One line describing a sync, in the same words the other clients use.
  String _describeSync(L10n l10n, SyncResult result) {
    final merge = result.merge;
    final parts = <String>[];
    if (merge != null && merge.changes > 0) {
      parts.add(
        l10n.tr('Merged %(changes)s change(s) from %(device)s.', {
          'changes': '${merge.changes}',
          'device': merge.sourceDevice.isEmpty
              ? l10n.tr('another device')
              : merge.sourceDevice,
        }),
      );
    } else if (merge != null) {
      parts.add(l10n.tr('Already up to date.'));
    }
    parts.add(
      result.pushed
          ? l10n.tr('Published a fresh snapshot.')
          : l10n.tr('Nothing needed publishing.'),
    );
    if ((merge?.conflicts.length ?? 0) > 0) {
      parts.add(
        l10n.tf('%s note(s) about edits made on both devices are in the sync report.', [
          '${merge!.conflicts.length}',
        ]),
      );
    }
    return parts.join(' ');
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: kSlate500,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// One theme's colour, ticked when it is the one in use. The tick is drawn in
/// the theme's own ink, so a yellow row shows the dark-on-gold it will get.
class _ThemeDot extends StatelessWidget {
  const _ThemeDot({required this.theme, required this.selected});

  final ColorTheme theme;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(color: theme.accent, shape: BoxShape.circle),
      child: selected ? Icon(Icons.check, size: 18, color: theme.ink) : null,
    );
  }
}
