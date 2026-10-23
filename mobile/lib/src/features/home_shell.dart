import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/l10n_scope.dart';

/// The persistent bottom navigation that wraps the six main sections.
///
/// Each branch keeps its own navigation stack (``StatefulShellRoute``), so
/// switching tabs feels like the web app's separate pages.
///
/// The bar is deliberately icon-only: six labels in a long translation would
/// not fit a narrow phone, and every section already names itself in its
/// app bar. The labels stay on the destinations for tooltips and screen
/// readers.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.dashboard_outlined),
            selectedIcon: const Icon(Icons.dashboard),
            label: l10n.tr('Dashboard'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.menu_book_outlined),
            selectedIcon: const Icon(Icons.menu_book),
            label: l10n.tr('Catalog'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.travel_explore_outlined),
            selectedIcon: const Icon(Icons.travel_explore),
            label: l10n.tr('Discover'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.auto_stories_outlined),
            selectedIcon: const Icon(Icons.auto_stories),
            label: l10n.tr('Reading stats'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.warehouse_outlined),
            selectedIcon: const Icon(Icons.warehouse),
            label: l10n.tr('Locations'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.label_outline),
            selectedIcon: const Icon(Icons.label),
            label: l10n.tr('Statuses'),
          ),
        ],
      ),
    );
  }
}
