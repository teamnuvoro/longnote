import 'package:flutter/widgets.dart';

import '../icons.dart';
import '../tokens.dart';
import 'pressable.dart';

/// Floating "Record" pill (Figma RecordPill 2:166). Bottom-centre on the
/// Notes tab, above the tab bar. Ink fill, white text, red dot in a ring.
class LnRecordPill extends StatelessWidget {
  const LnRecordPill({super.key, this.onPressed, this.label = 'Record'});

  final VoidCallback? onPressed;

  /// "Record", or e.g. "Recording 12:04" while a recording runs in the background.
  final String label;

  @override
  Widget build(BuildContext context) {
    return LnPressable(
      onPressed: onPressed,
      semanticLabel: label,
      pressedOpacity: 0.8,
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 16, 26, 16),
        decoration: BoxDecoration(
          color: LnColors.ink,
          borderRadius: BorderRadius.circular(LnRadius.pill),
          boxShadow: LnShadows.recordPill,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const LnIcon(LnIcons.recordDot, size: 22, color: null),
          const SizedBox(width: 12),
          Text(label, style: LnText.headline.copyWith(color: LnColors.card)),
        ]),
      ),
    );
  }
}
