import 'package:flutter/widgets.dart';

import '../icons.dart';
import '../tokens.dart';
import 'buttons.dart';
import 'pressable.dart';

/// Section label above a card group ("Today", "Waiting & needs attention"),
/// Geist SemiBold 13 ink2, with an optional amber mono count on the right.
class LnSectionLabel extends StatelessWidget {
  const LnSectionLabel(this.text, {super.key, this.count, this.trailing});
  final String text;
  final int? count;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
        child: Row(children: [
          Expanded(child: Text(text, style: LnText.sectionLabel)),
          if (count != null) Text('$count', style: LnText.monoCount),
          ?trailing,
        ]),
      );
}

/// Upper-case label inside a summary ("DECISIONS", "ACTION ITEMS").
class LnOverline extends StatelessWidget {
  const LnOverline(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: LnText.overline);
}

/// Round speaker avatar with an initial (28 px in transcripts, 18 in summaries).
class LnSpeakerAvatar extends StatelessWidget {
  const LnSpeakerAvatar(
      {super.key, required this.name, required this.colorIndex, this.size = 28});
  final String name;
  final int colorIndex;
  final double size;
  @override
  Widget build(BuildContext context) {
    final t = name.trim();
    final initial = t.isEmpty ? '?' : t.characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
          color: LnSpeakerColors.of(colorIndex), shape: BoxShape.circle),
      child: Text(initial,
          style: LnText.smallButton.copyWith(
              color: LnColors.card, fontSize: size >= 28 ? 12 : 10)),
    );
  }
}

/// Tab-root header: large Newsreader title with an optional trailing widget
/// (e.g. the trial chip). Padding 12 top, 14 bottom (Figma B1/G1).
class LnLargeTitle extends StatelessWidget {
  const LnLargeTitle(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 14),
        child: Row(children: [
          Expanded(child: Text(title, style: LnText.largeTitle)),
          ?trailing,
        ]),
      );
}

/// Detail top bar (Figma D2/D3): "< Notes" back button on the left and
/// action widgets on the right. 44 px high.
class LnTopBar extends StatelessWidget implements PreferredSizeWidget {
  const LnTopBar(
      {super.key, this.backLabel = 'Back', this.onBack, this.actions = const []});
  final String backLabel;
  final VoidCallback? onBack;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(44);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 16),
          child: Row(children: [
            if (onBack != null)
              LnPressable(
                onPressed: onBack,
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
            const Spacer(),
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              actions[i],
            ],
          ]),
        ),
      ),
    );
  }
}

/// Convenience: the round share / more buttons of the top bar.
class LnTopBarIcon extends StatelessWidget {
  const LnTopBarIcon(this.icon, {super.key, this.onPressed, this.semanticLabel});
  final LnIcons icon;
  final VoidCallback? onPressed;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) => LnIconButton(
      icon: icon, onPressed: onPressed, semanticLabel: semanticLabel);
}
