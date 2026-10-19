import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/l10n.dart';
import '../core/providers.dart';
import '../theme.dart';
import '../widgets/app_bar.dart';
import '../widgets/feedback.dart';
import '../widgets/guarded.dart';
import '../widgets/l10n_scope.dart';

/// Connection details, account, language and a way out.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _server;
  bool _testing = false;

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
    final ok = await runGuarded(context, ref, () async {
      await ref.read(apiClientProvider).me();
      return true;
    }, successMessage: context.localized.tr('Connected.'));
    if (mounted) setState(() => _testing = false);
    if (ok == null && mounted) {
      // runGuarded already reported the failure.
    }
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
                      session.user!.isAdmin ? l10n.tr('Administrator') : l10n.tr('Member'),
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
              if (confirmed) {
                await ref.read(sessionProvider.notifier).signOut();
                if (context.mounted) context.goNamed('login');
              }
            },
            icon: const Icon(Icons.logout, size: 18),
            label: Text(l10n.tr('Sign out')),
          ),

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
