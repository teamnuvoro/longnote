import 'package:flutter/widgets.dart';

import '../icons.dart';
import '../tokens.dart';
import 'pressable.dart';

/// Small rounded-rect chip on the quiet fill ("Trial · 2 days left").
class LnChip extends StatelessWidget {
  const LnChip(this.label, {super.key, this.onTap, this.selected = false});
  final String label;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: selected ? LnColors.ink : LnColors.fill,
          borderRadius: BorderRadius.circular(LnRadius.chip)),
      child: Text(label,
          style: LnText.chip
              .copyWith(color: selected ? LnColors.card : LnColors.ink2)),
    );
    return onTap == null ? c : LnPressable(onPressed: onTap, child: c);
  }
}

/// Pill chip with an optional icon. On the dark recording screen
/// ([dark] = true) it is the "English" / "Mark moment" chip (C1); on light
/// screens it is a source chip / speed chip.
class LnPillChip extends StatelessWidget {
  const LnPillChip({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.dark = false,
    this.selected = false,
  });

  final String label;
  final LnIcons? icon;
  final VoidCallback? onTap;
  final bool dark;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final Color bg, fg, border;
    if (dark) {
      bg = LnColors.nightRaised;
      fg = LnColors.nightText2;
      border = LnColors.nightFill;
    } else if (selected) {
      bg = LnColors.ink;
      fg = LnColors.card;
      border = LnColors.ink;
    } else {
      bg = LnColors.card;
      fg = LnColors.ink;
      border = LnColors.line;
    }
    final c = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(LnRadius.pill),
        border: Border.all(color: border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          LnIcon(icon!, size: 14, color: fg),
          const SizedBox(width: 6),
        ],
        Text(label, style: LnText.caption.copyWith(color: fg)),
      ]),
    );
    return onTap == null ? c : LnPressable(onPressed: onTap, child: c);
  }
}
