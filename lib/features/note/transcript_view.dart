import 'package:flutter/widgets.dart';

import '../../core/models/recording.dart';
import '../../ui/widgets.dart';
import 'kit.dart';
import 'note_model.dart';

/// One entry of the transcript list: a turn or a call-gap marker.
class TranscriptEntry {
  const TranscriptEntry.turn(this.index) : gap = null;
  const TranscriptEntry.gap(this.gap) : index = -1;
  final int index;
  final RecordingGap? gap;
}

/// Turns with gap markers placed before the first turn after each gap.
/// [filter] keeps only some turn indexes (transcript search).
List<TranscriptEntry> transcriptEntries(NoteData d, {Set<int>? filter}) {
  final out = <TranscriptEntry>[];
  final gaps = d.gaps.where((g) => g.endedAt != null).toList();
  var gi = 0;
  for (var i = 0; i < d.lines.length; i++) {
    while (filter == null && gi < gaps.length && gaps[gi].atMs <= d.lines[i].startMs) {
      out.add(TranscriptEntry.gap(gaps[gi++]));
    }
    if (filter == null || filter.contains(i)) out.add(TranscriptEntry.turn(i));
  }
  if (filter == null) {
    while (gi < gaps.length) {
      out.add(TranscriptEntry.gap(gaps[gi++]));
    }
  }
  return out;
}

/// "Paused 2 min for a phone call" (Figma D3).
class GapMarker extends StatelessWidget {
  const GapMarker({super.key, required this.gap});
  final RecordingGap gap;
  @override
  Widget build(BuildContext context) {
    final d = gap.endedAt!.difference(gap.startedAt);
    final len = d.inSeconds < 60 ? '${d.inSeconds} s' : '${d.inMinutes} min';
    final why = gap.reason == 'interruption' ? 'for a phone call' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        const Expanded(child: LnHairline()),
        const SizedBox(width: 8),
        const LnIcon(LnIcons.phone, size: 13, color: LnColors.ink3),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Text('Paused $len $why'.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: LnText.chip.copyWith(color: LnColors.ink3)),
        ),
        const SizedBox(width: 8),
        const Expanded(child: LnHairline()),
      ]),
    );
  }
}

/// A speaker turn (Figma D3 7:498). The highlight is drawn 10 px outside the
/// content so the text does not move when the playing line changes.
class TurnRow extends StatelessWidget {
  const TurnRow({
    super.key,
    required this.line,
    required this.name,
    required this.colorIndex,
    required this.showSpeaker,
    required this.highlighted,
    this.query,
    this.onTap,
  });

  final TranscriptLine line;
  final String name;
  final int colorIndex;
  final bool showSpeaker;
  final bool highlighted;
  final String? query;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = LnSpeakerColors.of(colorIndex);
    final q = query;
    final text = q == null || q.isEmpty
        ? Text(line.text, style: LnText.turn)
        : Text.rich(TextSpan(
            children: markedSpans(markMatches(line.text, q), LnText.turn,
                LnText.turn.copyWith(
                    fontWeight: FontWeight.w600,
                    fontVariations: const [FontVariation('wght', 600)],
                    backgroundColor: LnColors.highlight))));
    final time = Text(clockText(line.startMs), style: LnText.monoSmall);
    final content = showSpeaker && line.speaker != null
        ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LnSpeakerAvatar(name: name, colorIndex: colorIndex),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: LnText.speakerName.copyWith(color: color)),
                  ),
                  const SizedBox(width: 8),
                  time,
                ]),
                const SizedBox(height: 3),
                text,
              ]),
            ),
          ])
        : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 52,
                child: Padding(padding: const EdgeInsets.only(top: 3), child: time)),
            Expanded(child: text),
          ]);
    return LnPressable(
      onPressed: onTap,
      pressedOpacity: 0.7,
      semanticLabel: 'Play from ${clockText(line.startMs)}',
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: -10,
          right: -10,
          top: 0,
          bottom: 0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: highlighted ? LnColors.highlight : const Color(0x00FFF4D6),
              borderRadius: BorderRadius.circular(LnRadius.turn),
            ),
          ),
        ),
        Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: content),
      ]),
    );
  }
}
