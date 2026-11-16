import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/recording/recording_repository.dart';
import '../../ui/widgets.dart';
import 'kit.dart';
import 'note_model.dart';
import 'note_playback.dart';

/// D7 Full player (Figma 8:694): scrub on the waveform (coloured ticks where
/// each speaker starts), ±15 s, speeds and the moments marked while recording.
class PlayerSheet extends StatefulWidget {
  const PlayerSheet({super.key, required this.id});
  final String id;

  /// Reads the waveform; swapped in widget tests.
  static Future<List<double>> Function(List<String> paths, List<int> partMs)
      peaksLoader = waveformPeaks;

  @override
  State<PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends State<PlayerSheet> {
  late final NoteModel _model;
  NotePlayback? _player;
  List<double> _peaks = const [];
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _model = NoteModel(context.read<RecordingRepository>(), widget.id)
      ..addListener(_onData);
  }

  void _onData() {
    final d = _model.data;
    if (_model.gone) {
      // Once: a second repository change during the dismiss animation would
      // otherwise pop the screen under this sheet.
      if (mounted && !_closing) {
        _closing = true;
        context.pop();
      }
      return;
    }
    if (d == null) return;
    if (_player == null && d.hasPlayback) {
      final paths = d.playbackPaths(_model.repo.storage);
      final ms = d.playbackDurations;
      _player = NotePlaybacks.acquire(widget.id, () => NotePlayback(paths, ms));
      if (d.hasWaveform) {
        PlayerSheet.peaksLoader(paths, ms).then((p) {
          if (mounted) setState(() => _peaks = p);
        });
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _model
      ..removeListener(_onData)
      ..dispose();
    if (_player != null) NotePlaybacks.release(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = _model.data;
    final p = _player;
    return LnSheet(
      scrollable: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: d == null || p == null
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text(d == null ? '' : 'This note has no audio yet.',
                  textAlign: TextAlign.center, style: LnText.meta),
            )
          : ListenableBuilder(
              listenable: p,
              builder: (context, _) => _body(d, p),
            ),
    );
  }

  Widget _body(NoteData d, NotePlayback p) {
    final pos = p.positionMs;
    final turn = d.turnAt(pos);
    final who = turn >= 0 && d.lines[turn].speaker != null
        ? '${d.nameOf(d.lines[turn].speaker)} · '
        : '';
    // First turn of each speaker -> coloured tick.
    final ticks = <(double, int)>[];
    final seen = <String>{};
    if (p.totalMs > 0) {
      for (final l in d.lines) {
        final k = l.speaker;
        if (k != null && seen.add(k)) {
          ticks.add((l.startMs / p.totalMs, d.colorOf(k)));
        }
      }
    }
    final momentFrac = [
      if (p.totalMs > 0)
        for (final m in d.moments) m.atMs / p.totalMs
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(d.note.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: LnText.noteTitle),
        const SizedBox(height: 2),
        Text('$who${clockText(pos)}',
            textAlign: TextAlign.center, style: LnText.caption),
        const SizedBox(height: 18),
        _Scrubber(
          peaks: _peaks,
          fraction: p.totalMs == 0 ? 0 : pos / p.totalMs,
          ticks: ticks,
          moments: momentFrac,
          onSeek: (f) => p.seekTo((f * p.totalMs).round()),
        ),
        Row(children: [
          Text(clockText(pos),
              style: LnText.monoTiny.copyWith(fontSize: 12)),
          const Spacer(),
          Text('−${clockText(p.totalMs - pos)}',
              style: LnText.monoTiny.copyWith(fontSize: 12, color: LnColors.ink3)),
        ]),
        const SizedBox(height: 18),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _Skip(icon: NoteIcons.back15, label: 'Back 15 seconds', onTap: () => p.skip(-15000)),
          const SizedBox(width: 36),
          LnPressable(
            onPressed: p.toggle,
            semanticLabel: p.playing ? 'Pause' : 'Play',
            child: Container(
              width: 68,
              height: 68,
              alignment: Alignment.center,
              decoration:
                  const BoxDecoration(color: LnColors.ink, shape: BoxShape.circle),
              child: LnIcon(p.playing ? LnIcons.pause : LnIcons.play,
                  size: 26, color: LnColors.card),
            ),
          ),
          const SizedBox(width: 36),
          _Skip(icon: NoteIcons.fwd15, label: 'Forward 15 seconds', onTap: () => p.skip(15000)),
        ]),
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (final s in NotePlayback.speeds) ...[
            if (s != NotePlayback.speeds.first) const SizedBox(width: 6),
            _SpeedChip(
              label: LnMiniPlayer.formatSpeed(s),
              selected: p.speed == s,
              onTap: () => p.setSpeed(s),
            ),
          ],
        ]),
        const SizedBox(height: 18),
        Text('Marked moments', style: LnText.sectionLabel),
        const SizedBox(height: 8),
        if (d.moments.isEmpty)
          Text('None yet. Tap “Mark moment” while recording to add one.',
              style: LnText.meta)
        else
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: LnColors.card,
              borderRadius: BorderRadius.circular(LnRadius.card),
              border: Border.all(color: LnColors.line),
            ),
            child: Column(children: [
              for (var i = 0; i < d.moments.length; i++) ...[
                if (i > 0)
                  const Padding(padding: EdgeInsets.only(left: 60), child: LnHairline()),
                LnPressable(
                  onPressed: () => p.playFrom(d.moments[i].atMs),
                  pressedOpacity: 0.7,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(children: [
                      const IconTile(child: LnIcon(LnIcons.bookmark, size: 18)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(d.moments[i].label ?? 'Moment ${i + 1}',
                                  style: LnText.rowTitleSmall),
                              const SizedBox(height: 2),
                              Text(clockText(d.moments[i].atMs), style: LnText.meta),
                            ]),
                      ),
                    ]),
                  ),
                ),
              ],
            ]),
          ),
      ],
    );
  }
}

class _Skip extends StatelessWidget {
  const _Skip({required this.icon, required this.label, required this.onTap});
  final NoteIcons icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        semanticLabel: label,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          NoteIcon(icon, size: 28),
          const SizedBox(height: 2),
          Text('15',
              style: LnText.monoTiny.copyWith(
                  fontSize: 10,
                  color: LnColors.ink,
                  fontWeight: FontWeight.w500,
                  fontVariations: const [FontVariation('wght', 500)])),
        ]),
      );
}

class _SpeedChip extends StatelessWidget {
  const _SpeedChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        semanticLabel: 'Speed $label',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? LnColors.ink : LnColors.card,
            borderRadius: BorderRadius.circular(LnRadius.pill),
            border: Border.all(color: selected ? LnColors.ink : LnColors.line),
          ),
          child: Text(label,
              style: LnText.smallButton
                  .copyWith(color: selected ? LnColors.card : LnColors.ink)),
        ),
      );
}

/// Waveform scrubber, 80 px: bars (played = ink, rest = #C9C5BC), red
/// playhead, speaker ticks below. Tap or drag to seek.
class _Scrubber extends StatelessWidget {
  const _Scrubber({
    required this.peaks,
    required this.fraction,
    required this.ticks,
    required this.moments,
    required this.onSeek,
  });
  final List<double> peaks;
  final double fraction;
  final List<(double, int)> ticks;
  final List<double> moments;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) {
          double f(Offset o) => (o.dx / c.maxWidth).clamp(0.0, 1.0);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => onSeek(f(d.localPosition)),
            onHorizontalDragUpdate: (d) => onSeek(f(d.localPosition)),
            child: Semantics(
              label: 'Position',
              slider: true,
              value: '${(fraction * 100).round()}%',
              child: CustomPaint(
                size: Size(c.maxWidth, 80),
                painter: _ScrubPainter(peaks, fraction, ticks, moments),
              ),
            ),
          );
        },
      );
}

class _ScrubPainter extends CustomPainter {
  _ScrubPainter(this.peaks, this.fraction, this.ticks, this.moments);
  final List<double> peaks;
  final double fraction;
  final List<(double, int)> ticks;
  final List<double> moments;

  static const _rest = Color(0xFFC9C5BC);

  @override
  void paint(Canvas canvas, Size size) {
    const barW = 3.0;
    const step = 6.1;
    const mid = 36.0;
    final n = (size.width / step).floor();
    final head = fraction.clamp(0.0, 1.0) * size.width;
    final played = Paint()..color = LnColors.ink;
    final rest = Paint()..color = _rest;
    for (var i = 0; i < n; i++) {
      final v = peaks.isEmpty
          ? 0.12
          : peaks[(i * peaks.length / n).floor().clamp(0, peaks.length - 1)];
      final h = (4 + v * 64).clamp(4.0, 68.0);
      final x = i * step;
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x, mid - h / 2, barW, h),
              const Radius.circular(1.5)),
          x + barW / 2 <= head ? played : rest);
    }
    for (final t in ticks) {
      final x = t.$1 * size.width;
      final path = Path()
        ..moveTo(x - 4, 76)
        ..lineTo(x, 70)
        ..lineTo(x + 4, 76)
        ..close();
      canvas.drawPath(path, Paint()..color = LnSpeakerColors.of(t.$2));
    }
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(head - 1, 0, 2, 72), const Radius.circular(1)),
        Paint()..color = LnColors.signal);
  }

  @override
  bool shouldRepaint(_ScrubPainter old) =>
      old.fraction != fraction ||
      old.peaks != peaks ||
      old.ticks.length != ticks.length ||
      old.moments.length != moments.length;
}
