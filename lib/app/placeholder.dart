import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../ui/widgets.dart';
import 'routes.dart';

/// Stand-in for a screen the screens session still has to build. Shows the
/// title, the Figma frame and what the screen is for, plus optional links.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.route,
    required this.purpose,
    this.links = const [],
    this.tabRoot = false,
  });

  final String title;

  /// Route name (R.*); its Figma frame is looked up in [routeFrames].
  final String route;
  final String purpose;
  final List<Widget> links;

  /// Tab roots use the large title and no back button.
  final bool tabRoot;

  @override
  Widget build(BuildContext context) {
    final body = ListView(
      padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
      children: [
        if (tabRoot) LnLargeTitle(title) else ...[
          const SizedBox(height: 8),
          Text(title, style: LnText.detailTitle),
          const SizedBox(height: 16),
        ],
        _note(),
        if (links.isNotEmpty) ...[
          const SizedBox(height: LnSpace.section),
          LnCardGroup.settings(children: links),
        ],
        const SizedBox(height: 120),
      ],
    );
    return Scaffold(
      backgroundColor: LnColors.paper,
      appBar: tabRoot
          ? null
          : LnTopBar(
              backLabel: 'Back',
              onBack: () => context.canPop() ? context.pop() : context.goNamed(R.notes)),
      body: SafeArea(bottom: false, child: body),
    );
  }

  Widget _note() => Container(
        padding: const EdgeInsets.all(LnSpace.lg),
        decoration: BoxDecoration(
          color: LnColors.card,
          borderRadius: BorderRadius.circular(LnRadius.card),
          border: Border.all(color: LnColors.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LnOverline('To build · Figma ${routeFrames[route] ?? '-'}'),
          const SizedBox(height: 8),
          Text(purpose, style: LnText.bullet),
        ]),
      );
}

/// Stand-in for a sheet frame.
class PlaceholderSheet extends StatelessWidget {
  const PlaceholderSheet(
      {super.key, required this.title, required this.route, required this.purpose});
  final String title;
  final String route;
  final String purpose;

  @override
  Widget build(BuildContext context) {
    return LnSheet(
      title: title,
      subtitle: 'Figma ${routeFrames[route] ?? '-'} · to build',
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        LnCardGroup(children: [
          Padding(
            padding: const EdgeInsets.all(LnSpace.lg),
            child: Text(purpose, style: LnText.bullet),
          ),
        ]),
        const SizedBox(height: LnSpace.md),
        LnSecondaryButton(label: 'Close', onPressed: () => context.pop()),
      ]),
    );
  }
}
