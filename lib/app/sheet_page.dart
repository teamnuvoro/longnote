import 'package:flutter/material.dart';

import '../ui/tokens.dart';

/// go_router page that shows its child as a modal bottom sheet (scrim,
/// drag to dismiss). Use for every "sheet" frame (B4, C4, D4-D7, E3, F2).
/// The child should be an [LnSheet].
class SheetPage<T> extends Page<T> {
  const SheetPage({required this.child, super.key, super.name, super.arguments});

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) => ModalBottomSheetRoute<T>(
        settings: this,
        builder: (_) => child,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        modalBarrierColor: LnColors.scrim,
        elevation: 0,
      );
}
