import 'package:flutter/widgets.dart';

/// iOS-style press feedback: the child dims while pressed. No ripple.
class LnPressable extends StatefulWidget {
  const LnPressable({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.pressedOpacity = 0.55,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final double pressedOpacity;
  final String? semanticLabel;

  @override
  State<LnPressable> createState() => _LnPressableState();
}

class _LnPressableState extends State<LnPressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null || widget.onLongPress != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: enabled ? () => _set(false) : null,
        onTap: widget.onPressed,
        onLongPress: widget.onLongPress,
        child: AnimatedOpacity(
          duration: Duration(milliseconds: _down ? 0 : 150),
          opacity: !enabled ? 0.4 : (_down ? widget.pressedOpacity : 1),
          child: widget.child,
        ),
      ),
    );
  }
}
