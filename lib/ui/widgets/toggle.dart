import 'package:flutter/widgets.dart';

import '../tokens.dart';

/// iOS-style switch drawn to the Figma size: 44 x 26 track (40 x 24 when
/// [small], as next to "Speakers" in D3), ink when on, white knob.
class LnToggle extends StatelessWidget {
  const LnToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.small = false,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool small;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final w = small ? 40.0 : 44.0;
    final h = small ? 24.0 : 26.0;
    final knob = h - 6;
    return Semantics(
      toggled: value,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: w,
          height: h,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: value ? LnColors.ink : LnColors.line,
            borderRadius: BorderRadius.circular(h / 2),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: knob,
              height: knob,
              decoration: const BoxDecoration(
                color: LnColors.card,
                shape: BoxShape.circle,
                boxShadow: LnShadows.knob,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
