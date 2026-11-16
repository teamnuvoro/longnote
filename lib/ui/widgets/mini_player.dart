import 'package:flutter/widgets.dart';

import '../icons.dart';
import '../tokens.dart';
import 'pressable.dart';

/// Mini audio player shell (Figma D2/D3 MiniPlayer): play button, progress
/// track, mono times, speed chip, expand chevron. Pure view; wire it to
/// `PlaybackController` (lib/features/detail/playback_controller.dart).
class LnMiniPlayer extends StatelessWidget {
  const LnMiniPlayer({
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    this.speed = 1.0,
    this.onPlayPause,
    this.onSpeed,
    this.onExpand,
    this.onSeekFraction,
  });

  final bool playing;
  final Duration position;
  final Duration duration;
  final double speed;
  final VoidCallback? onPlayPause;
  final VoidCallback? onSpeed;
  final VoidCallback? onExpand;

  /// Tap on the track: 0..1.
  final ValueChanged<double>? onSeekFraction;

  static String formatTime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  static String formatSpeed(double s) =>
      '${s == s.roundToDouble() ? s.toStringAsFixed(0) : s.toString()}×';

  @override
  Widget build(BuildContext context) {
    final frac = duration.inMilliseconds == 0
        ? 0.0
        : position.inMilliseconds / duration.inMilliseconds;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: LnColors.card,
        borderRadius: BorderRadius.circular(LnRadius.miniPlayer),
        border: Border.all(color: LnColors.line),
        boxShadow: LnShadows.miniPlayer,
      ),
      child: Row(children: [
        LnPressable(
          onPressed: onPlayPause,
          semanticLabel: playing ? 'Pause' : 'Play',
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration:
                const BoxDecoration(color: LnColors.ink, shape: BoxShape.circle),
            child: LnIcon(playing ? LnIcons.pause : LnIcons.play,
                size: 16, color: LnColors.card),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            LayoutBuilder(
              builder: (context, c) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: onSeekFraction == null
                    ? null
                    : (d) => onSeekFraction!(
                        (d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      height: 4,
                      child: Stack(children: [
                        Container(color: LnColors.fill),
                        FractionallySizedBox(
                            widthFactor: frac.clamp(0.0, 1.0),
                            child: Container(color: LnColors.ink)),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(formatTime(position), style: LnText.monoTiny),
              Text(formatTime(duration),
                  style: LnText.monoTiny.copyWith(color: LnColors.ink3)),
            ]),
          ]),
        ),
        const SizedBox(width: 12),
        LnPressable(
          onPressed: onSpeed,
          child: Container(
            width: 36,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: LnColors.fill, borderRadius: BorderRadius.circular(8)),
            child: Text(formatSpeed(speed), style: LnText.smallButton),
          ),
        ),
        const SizedBox(width: 12),
        LnPressable(
          onPressed: onExpand,
          semanticLabel: 'Open player',
          child: const LnIcon(LnIcons.chevronUp, size: 20, color: LnColors.ink2),
        ),
      ]),
    );
  }
}
