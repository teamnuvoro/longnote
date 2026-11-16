import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../ui/widgets.dart';

/// The 4-tab shell: Notes, Ask, Import, Settings (Figma TabBar 2:165).
/// Each tab keeps its own navigation stack. The Record pill is drawn by the
/// Notes screen, not here.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: LnColors.paper,
      body: shell,
      bottomNavigationBar: LnTabBar(
        currentIndex: shell.currentIndex,
        // Tapping the current tab again goes back to its root.
        onTap: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
      ),
    );
  }
}
