import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/recording/recording_controller.dart';
import '../note/kit.dart';

/// C4 Discard confirm (Figma 6:579): a centred dark card. "Keep recording"
/// is the safe default and recording never stops while this is open.
/// Pops `true` when the user chooses to discard.
class DiscardSheet extends StatelessWidget {
  const DiscardSheet({super.key});

  @override
  Widget build(BuildContext context) {
    RecordingController? c;
    try {
      c = context.watch<RecordingController>();
    } on ProviderNotFoundException {
      c = null;
    }
    final lost = c == null ? null : spokenLength(c.elapsed);
    return ConfirmCard(
      dark: true,
      title: 'Discard this recording?',
      body: lost == null
          ? 'The audio will be deleted from this phone. This can’t be undone.'
          : '${lost[0].toUpperCase()}${lost.substring(1)} of audio will be deleted from this phone. This can’t be undone.',
      confirmLabel: 'Discard recording',
      cancelLabel: 'Keep recording',
      onConfirm: () => context.pop(true),
      onCancel: () => context.pop(false),
    );
  }
}

/// go_router page for centred dialogs (C4): fades in over a dark scrim,
/// tap outside = Keep recording.
class DialogPage<T> extends Page<T> {
  const DialogPage({required this.child, super.key, super.name});
  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) => RawDialogRoute<T>(
        settings: this,
        barrierDismissible: true,
        barrierLabel: 'Keep recording',
        barrierColor: const Color(0x99000000),
        transitionDuration: const Duration(milliseconds: 220),
        transitionBuilder: (c, a, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
          child: ScaleTransition(
            scale: Tween(begin: 0.96, end: 1.0)
                .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
        pageBuilder: (c, _, _) => child,
      );
}
