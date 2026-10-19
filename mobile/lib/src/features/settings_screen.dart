import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/l10n.dart';
import '../core/prefs.dart';
import '../core/providers.dart';
import '../local/library_files.dart';
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

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: ref.read(sessionProvider).baseUrl);
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
    setState(() => _testing = true);
    await runGuarded(context, ref, () async {
      await ref.read(apiClientProvider).me();
      return true;
    }, successMessage: context.localized.tr('Connected.'));
    if (mounted) setState(() => _testing = false);
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
                          color: session.user!.isAdmin ? kBrand : kSlate400,
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
                      color: option.code == language ? kBrand : kSlate500,
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
