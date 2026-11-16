import 'package:flutter/widgets.dart';

import '../icons.dart';
import '../tokens.dart';
import 'pressable.dart';
import 'toggle.dart';

/// White card with a hairline border and radius 16; children are separated by
/// 1 px hairline dividers inset by [dividerInset] on the left (16 for note
/// rows, 52 for settings rows with a 20 px icon) and [dividerEndInset] on the right.
class LnCardGroup extends StatelessWidget {
  const LnCardGroup({
    super.key,
    required this.children,
    this.dividerInset = 16,
    this.dividerEndInset = 16,
  });

  /// Settings-style rows (icon + label): divider starts after the icon.
  const LnCardGroup.settings({super.key, required this.children})
      : dividerInset = 52,
        dividerEndInset = 0;

  final List<Widget> children;
  final double dividerInset;
  final double dividerEndInset;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        items.add(Padding(
          padding: EdgeInsets.only(left: dividerInset, right: dividerEndInset),
          child: const LnHairline(),
        ));
      }
      items.add(children[i]);
    }
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: LnColors.card,
        borderRadius: BorderRadius.circular(LnRadius.card),
        border: Border.all(color: LnColors.line),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: items),
    );
  }
}

/// 1 px line in the hairline colour.
class LnHairline extends StatelessWidget {
  const LnHairline({super.key, this.color = LnColors.line});
  final Color color;
  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: color);
}

/// Settings / sheet list row: [icon] label ........ value  >
/// (Figma G1 rows: px 14, py 13, gap 14, icon 20, Geist Medium 15).
class LnListRow extends StatelessWidget {
  const LnListRow({
    super.key,
    required this.label,
    this.icon,
    this.value,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.showChevron,
    this.destructive = false,
    this.large = false,
  });

  /// A row whose trailing widget is an [LnToggle].
  factory LnListRow.toggle({
    Key? key,
    required String label,
    LnIcons? icon,
    String? subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) =>
      LnListRow(
        key: key,
        label: label,
        icon: icon,
        subtitle: subtitle,
        onTap: onChanged == null ? null : () => onChanged(!value),
        showChevron: false,
        trailing: LnToggle(value: value, onChanged: onChanged),
      );

  final String label;
  final LnIcons? icon;
  final String? value;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// Defaults to true when [onTap] is set and there is no [trailing].
  final bool? showChevron;

  /// Red text and icon ("Delete note…").
  final bool destructive;

  /// Sheet action rows: 16 px label, py 15, px 16 (Figma B4).
  final bool large;

  @override
  Widget build(BuildContext context) {
    final fg = destructive ? LnColors.destructiveText : LnColors.ink;
    final chevron = showChevron ?? (onTap != null && trailing == null);
    final row = Padding(
      padding: EdgeInsets.symmetric(
          horizontal: large ? 16 : 14, vertical: large ? 15 : 13),
      child: Row(children: [
        if (icon != null) ...[
          LnIcon(icon!, size: 20, color: fg),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (large ? LnText.sheetRowLabel : LnText.rowLabel)
                      .copyWith(color: fg)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: LnText.meta),
              ],
            ],
          ),
        ),
        if (value != null) ...[
          const SizedBox(width: 8),
          Text(value!, style: LnText.rowValue),
        ],
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        if (chevron) ...[
          const SizedBox(width: 6),
          const LnIcon(LnIcons.chevronRight, size: 16, color: LnColors.ink3),
        ],
      ]),
    );
    return onTap == null ? row : LnPressable(onPressed: onTap, child: row);
  }
}

/// Thin progress bar (4 px, fill track, ink bar). [value] null = indeterminate
/// (shown as an empty track).
class LnProgressBar extends StatelessWidget {
  const LnProgressBar({super.key, this.value, this.color = LnColors.ink});
  final double? value;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 4,
        child: Stack(children: [
          Container(color: LnColors.fill),
          FractionallySizedBox(
            widthFactor: (value ?? 0).clamp(0.0, 1.0),
            child: Container(
                decoration: BoxDecoration(
                    color: color, borderRadius: BorderRadius.circular(2))),
          ),
        ]),
      ),
    );
  }
}

/// A note in the Notes list (Figma B1 NoteRow): title + mono duration, then
/// either a preview line or a status line with a progress bar.
class LnNoteRow extends StatelessWidget {
  const LnNoteRow({
    super.key,
    required this.title,
    required this.duration,
    this.preview,
    this.status,
    this.progress,
    this.onTap,
    this.onLongPress,
  });

  final String title;

  /// Already formatted, e.g. "1:12:40".
  final String duration;
  final String? preview;

  /// e.g. "Transcribing · 64%". When set, a progress bar is shown.
  final String? status;
  final double? progress;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return LnPressable(
      onPressed: onTap,
      onLongPress: onLongPress,
      pressedOpacity: 0.7,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LnText.rowTitle),
            ),
            const SizedBox(width: 8),
            Text(duration, style: LnText.monoSmall),
          ]),
          const SizedBox(height: 4),
          if (status != null) ...[
            Text(status!, style: LnText.caption),
            const SizedBox(height: 6),
            LnProgressBar(value: progress),
          ] else if (preview != null)
            Text(preview!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: LnText.preview),
        ]),
      ),
    );
  }
}

/// Row in "Waiting & needs attention" (Figma B1): amber icon tile, title,
/// reason, and trailing actions (Retry / trash).
class LnAttentionRow extends StatelessWidget {
  const LnAttentionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actions = const [],
    this.onTap,
  });

  final LnIcons icon;
  final String title;
  final String subtitle;
  final List<Widget> actions;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: LnColors.attentionTint,
              borderRadius: BorderRadius.circular(LnRadius.iconButton)),
          child: LnIcon(icon, size: 18, color: LnColors.attention),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: LnText.rowTitleSmall),
            const SizedBox(height: 2),
            Text(subtitle,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: LnText.meta),
          ]),
        ),
        for (final a in actions) ...[const SizedBox(width: 8), a],
      ]),
    );
    return onTap == null ? row : LnPressable(onPressed: onTap, child: row);
  }
}
