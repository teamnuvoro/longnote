import 'package:flutter/widgets.dart';

import '../icons.dart';
import '../tokens.dart';

enum LnStatus { recording, paused, saved }

/// Status pills on the dark recording screen (Figma C1/C2): "● Recording"
/// (red), "● Paused" (amber), "✓ Saved" (green).
class LnStatusPill extends StatelessWidget {
  const LnStatusPill(this.status, {super.key, this.label});

  final LnStatus status;

  /// Overrides the default text ("Recording" / "Paused" / "Saved").
  final String? label;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, text) = switch (status) {
      LnStatus.recording =>
        (LnColors.recordingPillBg, LnColors.recordingPillText, 'Recording'),
      LnStatus.paused => (LnColors.pausedPillBg, LnColors.pausedPillText, 'Paused'),
      LnStatus.saved => (LnColors.savedPillBg, LnColors.savedPillText, 'Saved'),
    };
    final saved = status == LnStatus.saved;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: saved ? 10 : 12, vertical: 7),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(LnRadius.pill)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (saved)
          LnIcon(LnIcons.check, size: 13, color: fg)
        else
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                color: status == LnStatus.recording ? LnColors.signal : fg,
                shape: BoxShape.circle),
          ),
        SizedBox(width: saved ? 6 : 8),
        Text(label ?? text, style: LnText.smallButton.copyWith(color: fg)),
      ]),
    );
  }
}
