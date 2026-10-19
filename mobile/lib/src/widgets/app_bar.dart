/// The toolbar every screen uses, so the overflow menu lives in one place.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/providers.dart';
import 'feedback.dart';
import 'l10n_scope.dart';

/// One entry in a screen's overflow menu.
class LibraryAppBarItem {
  const LibraryAppBarItem(
    this.value,
    this.label,
    this.icon, {
    this.destructive = false,
  });

  final String value;
  final String label;
  final IconData icon;
  final bool destructive;
}

class LibraryAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const LibraryAppBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.bottom,
    this.showSync = true,
    this.extraItems = const [],
    this.onExtraSelected,
  });

  final String title;
  final List<Widget> actions;
  final PreferredSizeWidget? bottom;
  final bool showSync;

  /// Extra entries for the overflow menu (delete, copy, …).
  final List<LibraryAppBarItem> extraItems;
  final ValueChanged<String>? onExtraSelected;

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.localized;
    final session = ref.watch(sessionProvider);
    return AppBar(
      title: Text(title),
      actions: [
        ...actions,
        if (showSync)
          IconButton(
            tooltip: l10n.tr('Refresh'),
            icon: const Icon(Icons.sync),
            onPressed: () {
              refreshEverything(ref);
              showSnack(context, l10n.tr('Reloading from the server…'));
            },
          ),
        PopupMenuButton<String>(
          tooltip: l10n.tr('More'),
          onSelected: (value) async {
            switch (value) {
              case 'settings':
                await context.pushNamed('settings');
              case 'about':
                await context.pushNamed('about');
              case 'signout':
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
                }
              default:
                onExtraSelected?.call(value);
            }
          },
          itemBuilder: (context) => [
            for (final item in extraItems) ...[
              PopupMenuItem(
                value: item.value,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    item.icon,
                    color: item.destructive ? Theme.of(context).colorScheme.error : null,
                  ),
                  title: Text(
                    item.label,
                    style: item.destructive
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                  ),
                ),
              ),
            ],
            if (extraItems.isNotEmpty) const PopupMenuDivider(),
            PopupMenuItem(
              value: 'settings',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.settings_outlined),
                title: Text(l10n.tr('Settings')),
              ),
            ),
            PopupMenuItem(
              value: 'about',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.info_outline),
                title: Text(l10n.tr('About')),
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'signout',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.logout),
                title: Text(l10n.tr('Sign out')),
                subtitle: session.user == null ? null : Text(session.user!.shown),
              ),
            ),
          ],
        ),
      ],
      bottom: bottom,
    );
  }
}
