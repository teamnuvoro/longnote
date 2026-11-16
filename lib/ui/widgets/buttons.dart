import 'package:flutter/widgets.dart';

import '../icons.dart';
import '../tokens.dart';
import 'pressable.dart';

/// Full-width 54 px button (Figma Button/Primary 2:170, Secondary 2:172,
/// Destructive 2:174). Radius 14, Geist SemiBold 17.
class _LnBigButton extends StatelessWidget {
  const _LnBigButton({
    required this.label,
    required this.onPressed,
    required this.background,
    required this.foreground,
    this.border,
    this.icon,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color background;
  final Color foreground;
  final Color? border;
  final LnIcons? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return LnPressable(
      onPressed: busy ? null : onPressed,
      child: Container(
        height: 54,
        width: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(LnRadius.button),
          border: border == null ? null : Border.all(color: border!),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              LnIcon(icon!, size: 18, color: foreground),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(busy ? '$label…' : label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LnText.headline.copyWith(color: foreground)),
            ),
          ],
        ),
      ),
    );
  }
}

class LnPrimaryButton extends StatelessWidget {
  const LnPrimaryButton(
      {super.key, required this.label, this.onPressed, this.icon, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final LnIcons? icon;
  final bool busy;
  @override
  Widget build(BuildContext context) => _LnBigButton(
      label: label,
      onPressed: onPressed,
      icon: icon,
      busy: busy,
      background: LnColors.ink,
      foreground: LnColors.card);
}

class LnSecondaryButton extends StatelessWidget {
  const LnSecondaryButton(
      {super.key, required this.label, this.onPressed, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final LnIcons? icon;
  @override
  Widget build(BuildContext context) => _LnBigButton(
      label: label,
      onPressed: onPressed,
      icon: icon,
      background: LnColors.card,
      foreground: LnColors.ink,
      border: LnColors.line);
}

class LnDestructiveButton extends StatelessWidget {
  const LnDestructiveButton(
      {super.key, required this.label, this.onPressed, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final LnIcons? icon;
  @override
  Widget build(BuildContext context) => _LnBigButton(
      label: label,
      onPressed: onPressed,
      icon: icon,
      background: LnColors.destructiveTint,
      foreground: LnColors.signal);
}

/// Small ink button inside a row ("Retry"): px 12, py 8, radius 10.
class LnSmallButton extends StatelessWidget {
  const LnSmallButton({super.key, required this.label, this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    return LnPressable(
      onPressed: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: LnColors.ink,
            borderRadius: BorderRadius.circular(LnRadius.iconButton)),
        child: Text(label, style: LnText.smallButton.copyWith(color: LnColors.card)),
      ),
    );
  }
}

enum LnPillStyle {
  /// Ink fill, white text ("Ask" on the note top bar).
  ink,

  /// White fill, hairline border ("Edit names").
  outline,

  /// Quiet fill ("Change style" chips).
  fill,

  /// On dark surfaces ("Manage" on the plan card).
  onDark,
}

/// Rounded pill button with optional leading icon.
class LnPillButton extends StatelessWidget {
  const LnPillButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.style = LnPillStyle.outline,
  });

  final String label;
  final LnIcons? icon;
  final VoidCallback? onPressed;
  final LnPillStyle style;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (style) {
      LnPillStyle.ink => (LnColors.ink, LnColors.card, null),
      LnPillStyle.outline => (LnColors.card, LnColors.ink, LnColors.line),
      LnPillStyle.fill => (LnColors.fill, LnColors.ink, null),
      LnPillStyle.onDark => (LnColors.nightFill, LnColors.card, null),
    };
    final big = style == LnPillStyle.ink;
    return LnPressable(
      onPressed: onPressed,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: big ? 12 : 10, vertical: big ? 8 : 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(LnRadius.pill),
          border: border == null ? null : Border.all(color: border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            LnIcon(icon!, size: big ? 14 : 13, color: fg),
            const SizedBox(width: 6),
          ],
          Text(label,
              style: (big ? LnText.segmentSelected : LnText.smallButton)
                  .copyWith(color: fg)),
        ]),
      ),
    );
  }
}

enum LnIconButtonShape { round, square }

/// 36 px icon button on the quiet fill (share / more on the top bar are
/// round; trash in the attention list is square with radius 10).
class LnIconButton extends StatelessWidget {
  const LnIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.shape = LnIconButtonShape.round,
    this.size = 36,
    this.iconSize = 18,
    this.background = LnColors.fill,
    this.color = LnColors.ink,
    this.semanticLabel,
  });

  final LnIcons icon;
  final VoidCallback? onPressed;
  final LnIconButtonShape shape;
  final double size;
  final double iconSize;
  final Color background;
  final Color color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return LnPressable(
      onPressed: onPressed,
      semanticLabel: semanticLabel,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(
              shape == LnIconButtonShape.round ? LnRadius.pill : LnRadius.iconButton),
        ),
        child: LnIcon(icon, size: iconSize, color: color),
      ),
    );
  }
}
