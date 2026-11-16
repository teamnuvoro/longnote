import 'package:flutter/material.dart';

import '../tokens.dart';
import 'pressable.dart';

/// Bottom sheet body with the grabber (Figma B4, D4-D7, E3, F2): paper
/// background, radius 24 on top, 36 x 5 grabber, 16 px side padding.
///
/// Header options:
/// - [title] (+ [subtitle]) left-aligned, Newsreader 22 (B4 "note actions").
/// - [title] with [leadingAction]/[trailingAction] = the "Cancel  Speakers  Save"
///   bar of D4 (title centred, Geist SemiBold 17).
class LnSheet extends StatelessWidget {
  const LnSheet({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.leadingAction,
    this.trailingAction,
    this.scrollable = false,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final LnSheetAction? leadingAction;
  final LnSheetAction? trailingAction;

  /// Wrap [child] in a scroll view (long lists such as the language list).
  final bool scrollable;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final hasBar = leadingAction != null || trailingAction != null;
    Widget header = const SizedBox.shrink();
    if (hasBar) {
      header = Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
        child: Row(children: [
          Expanded(
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: leadingAction ?? const SizedBox.shrink())),
          if (title != null) Text(title!, style: LnText.headline),
          Expanded(
              child: Align(
                  alignment: Alignment.centerRight,
                  child: trailingAction ?? const SizedBox.shrink())),
        ]),
      );
    } else if (title != null) {
      header = Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title!, style: LnText.noteTitle),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: LnText.meta),
          ],
        ]),
      );
    }
    final body = Padding(
        padding: padding.copyWith(bottom: padding.bottom + bottom), child: child);
    return Material(
      color: LnColors.paper,
      borderRadius:
          const BorderRadius.vertical(top: Radius.circular(LnRadius.sheet)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LnGrabber(),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: header),
          // Loose: as tall as its content, but never taller than the space
          // the sheet has (a list inside then scrolls instead of
          // overflowing, e.g. E3 with many notes).
          Flexible(
              child: scrollable ? SingleChildScrollView(child: body) : body),
        ],
      ),
    );
  }
}

class LnGrabber extends StatelessWidget {
  const LnGrabber({super.key});
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          margin: const EdgeInsets.only(top: 10, bottom: 14),
          width: 36,
          height: 5,
          decoration: BoxDecoration(
              color: LnColors.grabber, borderRadius: BorderRadius.circular(3)),
        ),
      );
}

/// "Cancel" / "Save" text action in a sheet header.
class LnSheetAction extends StatelessWidget {
  const LnSheetAction(this.label,
      {super.key, this.onPressed, this.emphasized = false});
  final String label;
  final VoidCallback? onPressed;
  final bool emphasized;
  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(label,
              style: emphasized
                  ? LnText.headline
                  : LnText.headline.copyWith(
                      color: LnColors.ink2,
                      fontWeight: FontWeight.w500,
                      fontVariations: const [FontVariation('wght', 500)])),
        ),
      );
}

/// Shows [builder] as a modal sheet with the Longnote scrim and shape.
/// Prefer the router's sheet routes (lib/app/router.dart) for screens in the
/// Figma list; use this for small ad-hoc sheets.
Future<T?> showLnSheet<T>(BuildContext context,
    {required WidgetBuilder builder}) {
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: LnColors.scrim,
    builder: builder,
  );
}
