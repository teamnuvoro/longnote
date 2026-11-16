import 'package:flutter/material.dart';

import '../../ui/widgets.dart';

/// Push-screen bar with a centred title (Figma G2/G3/G4): "< Settings" on the
/// left, Geist SemiBold 17 title in the middle. 44 px high.
class LnNavBar extends StatelessWidget implements PreferredSizeWidget {
  const LnNavBar(
      {super.key, required this.title, this.backLabel = 'Back', this.onBack});
  final String title;
  final String backLabel;
  final VoidCallback? onBack;

  @override
  Size get preferredSize => const Size.fromHeight(44);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 44,
        child: Stack(alignment: Alignment.center, children: [
          Positioned(
            left: 12,
            top: 0,
            bottom: 0,
            child: LnPressable(
              key: const ValueKey('nav-back'),
              onPressed: onBack ?? () => Navigator.of(context).maybePop(),
              semanticLabel: backLabel,
              child: Row(children: [
                const LnIcon(LnIcons.chevronLeft, size: 24),
                const SizedBox(width: 2),
                Text(backLabel,
                    style: LnText.headline.copyWith(
                        fontWeight: FontWeight.w500,
                        fontVariations: const [FontVariation('wght', 500)])),
              ]),
            ),
          ),
          Text(title, style: LnText.headline),
        ]),
      ),
    );
  }
}

/// Rounded square icon tile on the quiet fill (F1 rows 34/10, G3 map 32/10,
/// F2/F3 file 40/12, A2 bell 40/12).
class LnIconTile extends StatelessWidget {
  const LnIconTile(this.icon,
      {super.key, this.size = 34, this.iconSize = 18, this.radius = 10});
  final LnIcons icon;
  final double size;
  final double iconSize;
  final double radius;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: LnColors.fill, borderRadius: BorderRadius.circular(radius)),
        child: LnIcon(icon, size: iconSize),
      );
}

/// 20 px radio: ink circle with a white check when selected, ink3 ring when not.
class LnRadioMark extends StatelessWidget {
  const LnRadioMark({super.key, required this.selected});
  final bool selected;
  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 20,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? LnColors.ink : null,
          shape: BoxShape.circle,
          border: selected
              ? null
              : Border.all(color: LnColors.ink3, width: 1.5),
        ),
        child: selected
            ? const LnIcon(LnIcons.check, size: 12, color: LnColors.card)
            : null,
      );
}

/// Small green tag ("Save 50%", "Recommended").
class LnGreenTag extends StatelessWidget {
  const LnGreenTag(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
            color: LnColors.savedTint,
            borderRadius: BorderRadius.circular(LnRadius.chip)),
        child: Text(label,
            style: LnText.chip.copyWith(
                color: LnColors.saved,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontVariations: const [FontVariation('wght', 600)])),
      );
}

/// White card with the hairline border (no dividers), radius 16.
class LnCard extends StatelessWidget {
  const LnCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    this.radius = LnRadius.card,
    this.selected = false,
  });
  final Widget child;
  final EdgeInsets padding;
  final double radius;

  /// 2 px ink border (selected plan / transcription mode).
  final bool selected;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: double.infinity,
        padding: selected ? padding - const EdgeInsets.all(1) : padding,
        decoration: BoxDecoration(
          color: LnColors.card,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
              color: selected ? LnColors.ink : LnColors.line,
              width: selected ? 2 : 1),
        ),
        child: child,
      );
}

/// Row inside a card group without an icon: label (+ subtitle) and an
/// optional check (G2 languages, E3 notes).
class LnCheckRow extends StatelessWidget {
  const LnCheckRow({
    super.key,
    required this.label,
    this.subtitle,
    this.checked = false,
    this.enabled = true,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    this.labelStyle,
    this.subtitleColor = LnColors.ink2,
  });
  final Color subtitleColor;
  final String label;
  final String? subtitle;
  final bool checked;
  final bool enabled;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    final style = (labelStyle ?? LnText.rowLabel)
        .copyWith(color: enabled ? null : LnColors.ink3);
    final row = Padding(
      padding: padding,
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: LnText.meta.copyWith(
                      height: 18 / 13,
                      color: enabled ? subtitleColor : LnColors.ink3)),
            ],
          ]),
        ),
        if (checked) ...[
          const SizedBox(width: 12),
          const LnIcon(LnIcons.check, size: 18),
        ],
      ]),
    );
    if (!enabled || onTap == null) {
      return Semantics(enabled: enabled, child: row);
    }
    return LnPressable(onPressed: onTap, pressedOpacity: 0.6, child: row);
  }
}

/// One row of a white card drawn as part of a lazily built list: the first
/// row gets the top corners, the last the bottom corners; rows in between
/// draw only the side borders and a divider.
class LnCardSlice extends StatelessWidget {
  const LnCardSlice({
    super.key,
    required this.child,
    required this.first,
    required this.last,
    this.dividerInset = 14,
  });
  final Widget child;
  final bool first;
  final bool last;
  final double dividerInset;

  @override
  Widget build(BuildContext context) {
    const r = Radius.circular(LnRadius.card);
    const side = BorderSide(color: LnColors.line);
    return Container(
      decoration: BoxDecoration(
        color: LnColors.card,
        borderRadius: BorderRadius.only(
          topLeft: first ? r : Radius.zero,
          topRight: first ? r : Radius.zero,
          bottomLeft: last ? r : Radius.zero,
          bottomRight: last ? r : Radius.zero,
        ),
        border: Border(
          left: side,
          right: side,
          top: first ? side : BorderSide.none,
          bottom: last ? side : BorderSide.none,
        ),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (!first)
          Padding(
              padding: EdgeInsets.only(left: dividerInset),
              child: const LnHairline()),
        child,
      ]),
    );
  }
}

/// [Scaffold] on the paper background. (It used to reset the default text
/// style to fix line heights; that is now done once in lib/ui/theme.dart.)
class LnScaffold extends StatelessWidget {
  const LnScaffold(
      {super.key, this.backgroundColor = LnColors.paper, this.appBar, this.body});
  final Color backgroundColor;
  final PreferredSizeWidget? appBar;
  final Widget? body;
  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: backgroundColor, appBar: appBar, body: body);
}

/// [LnSheet] with the A/E/F/G sheet padding.
class LnPlainSheet extends StatelessWidget {
  const LnPlainSheet({
    super.key,
    required this.child,
    this.title,
    this.scrollable = false,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
  });
  final Widget child;
  final String? title;
  final bool scrollable;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => LnSheet(
        title: title,
        scrollable: scrollable,
        padding: padding,
        child: child,
      );
}
