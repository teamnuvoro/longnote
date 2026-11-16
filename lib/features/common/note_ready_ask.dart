import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../ui/widgets.dart';
import 'external.dart';

bool _asking = false;

/// Asks once, at the first moment it helps (the user's first note has just
/// started processing), whether to send a "note ready" notification. A plain
/// sentence first; iOS's prompt only after "Notify me". Never asked again.
Future<void> askNoteReadyOnce(BuildContext context) async {
  final s = context.read<AppServices>();
  if (!s.noteReadyAskDue.value || _asking) return;
  _asking = true;
  try {
    final allow = await showLnSheet<bool>(context,
        builder: (_) => const NoteReadyAskSheet());
    final granted = await s.answerNoteReadyAsk(allow: allow == true);
    if (allow == true && !granted && context.mounted) {
      showNote(context,
          'Notifications are off. You can turn them on in iPhone Settings › Longnote.');
    }
  } finally {
    _asking = false;
  }
}

class NoteReadyAskSheet extends StatelessWidget {
  const NoteReadyAskSheet({super.key});

  @override
  Widget build(BuildContext context) => LnSheet(
        title: 'Tell you when it’s ready?',
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
              'A long recording takes a few minutes to become a note. We can send one notification when each note is ready, and nothing else.',
              style: LnText.body.copyWith(color: LnColors.ink2)),
          const SizedBox(height: 20),
          LnPrimaryButton(
              label: 'Notify me',
              onPressed: () => Navigator.of(context).pop(true)),
          const SizedBox(height: 10),
          LnSecondaryButton(
              label: 'Not now',
              onPressed: () => Navigator.of(context).pop(false)),
        ]),
      );
}
