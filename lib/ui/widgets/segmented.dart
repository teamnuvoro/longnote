import 'package:flutter/widgets.dart';

import '../tokens.dart';
import 'pressable.dart';

/// Segmented control (Figma D2/D3 "Summary | Transcript"): fill track with
/// 3 px padding, radius 10; selected segment white, radius 8, soft shadow.
class LnSegmentedControl<T> extends StatelessWidget {
  const LnSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  /// value -> label, in display order.
  final Map<T, String> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: LnColors.fill,
          borderRadius: BorderRadius.circular(LnRadius.segmentedTrack)),
      child: Row(children: [
        for (final e in segments.entries)
          Expanded(
            child: LnPressable(
              onPressed: () => onChanged(e.key),
              pressedOpacity: 0.8,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(vertical: 7),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: e.key == selected ? LnColors.card : null,
                  borderRadius: BorderRadius.circular(LnRadius.segment),
                  boxShadow: e.key == selected ? LnShadows.segment : null,
                ),
                child: Text(e.value,
                    style: e.key == selected
                        ? LnText.segmentSelected
                        : LnText.segment),
              ),
            ),
          ),
      ]),
    );
  }
}
