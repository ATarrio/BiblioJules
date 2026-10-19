import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../theme.dart';
import '../widgets/app_bar.dart';
import '../widgets/l10n_scope.dart';

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.localized;
    final session = ref.watch(sessionProvider);
    final user = session.user;
    return Scaffold(
      appBar: LibraryAppBar(title: l10n.tr('About %(app)s', {'app': kAppName}), showSync: false),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.local_library_outlined,
                    size: 30,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  kAppName,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '${l10n.tr('Version')} $kAppVersion',
                  style: const TextStyle(color: kSlate400),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.tr('The Android edition of BiblioJules. It keeps no catalogue of its own: it always reads and writes through the server below, so what you see here is the same collection as the web and desktop editions.'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(l10n.tr('Backend URL')),
                  subtitle: Text(session.baseUrl.isEmpty ? '—' : session.baseUrl),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(l10n.tr('Signed in as')),
                  subtitle: Text(
                    user == null
                        ? '—'
                        : '${user.shown} (${user.isAdmin ? l10n.tr('Administrator') : l10n.tr('Member')})',
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: Text(l10n.tr('Local database')),
                  subtitle: Text(l10n.tr('None — your books live on the server.')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
