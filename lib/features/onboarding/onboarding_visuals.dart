import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/icons.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/labels.dart';
import 'onboarding_content.dart';

/// Every animation here is finite (a few seconds at most), so widget tests
/// and the simulator QA can settle.

TextStyle _w(TextStyle s, double w) =>
    s.copyWith(fontWeight: FontWeight.values[(w ~/ 100) - 1],
        fontVariations: [FontVariation('wght', w)]);

/// Fades and slides [child] in after [delay] (from the moment it is built).
class Reveal extends StatefulWidget {
  const Reveal({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = 14,
    this.duration = const Duration(milliseconds: 420),
  });
  final Widget child;
  final Duration delay;
  final double offset;
  final Duration duration;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  // The delay is part of the animation (no Timer: tests settle cleanly).
  late final AnimationController _c = AnimationController(
      vsync: this, duration: widget.delay + widget.duration)
    ..forward();
  late final Animation<double> _a = CurvedAnimation(
      parent: _c,
      curve: Interval(
          widget.delay.inMilliseconds /
              (widget.delay + widget.duration).inMilliseconds,
          1,
          curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _a,
        builder: (context, child) => Opacity(
          opacity: _a.value,
          child: Transform.translate(
              offset: Offset(0, widget.offset * (1 - _a.value)), child: child),
        ),
        child: widget.child,
      );
}

/// Card used by the mock screens: white, hairline, soft shadow.
class MockCard extends StatelessWidget {
  const MockCard(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(16),
      this.color = LnColors.card,
      this.border = LnColors.line});
  final Widget child;
  final EdgeInsets padding;
  final Color color;
  final Color? border;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(18),
          border: border == null ? null : Border.all(color: border!),
          boxShadow: const [
            BoxShadow(
                color: Color(0x0D000000), blurRadius: 18, offset: Offset(0, 6)),
          ],
        ),
        child: child,
      );
}

/// Static audio bars (deterministic heights) that grow in once.
class WaveBars extends StatefulWidget {
  const WaveBars(
      {super.key,
      this.count = 34,
      this.height = 44,
      this.color = LnColors.signal,
      this.seed = 7});
  final int count;
  final double height;
  final Color color;
  final int seed;
  @override
  State<WaveBars> createState() => _WaveBarsState();
}

class _WaveBarsState extends State<WaveBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..forward();
  late final List<double> _h = () {
    final r = math.Random(widget.seed);
    return List.generate(widget.count, (i) {
      final env = 0.45 + 0.55 * math.sin(i / widget.count * math.pi);
      return (0.18 + r.nextDouble() * 0.82) * env;
    });
  }();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: widget.height,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < _h.length; i++)
                Container(
                  width: 3,
                  height: math.max(
                      3,
                      widget.height *
                          _h[i] *
                          Curves.easeOutBack.transform(
                              ((_c.value * 1.6) - i / _h.length * 0.6)
                                  .clamp(0.0, 1.0))),
                  decoration: BoxDecoration(
                      color: widget.color,
                      borderRadius: BorderRadius.circular(2)),
                ),
            ],
          ),
        ),
      );
}

/// A timer that counts up from [from] for [run], then stops.
class CountingTimer extends StatefulWidget {
  const CountingTimer(
      {super.key,
      required this.from,
      this.run = const Duration(seconds: 4),
      required this.style});
  final Duration from;
  final Duration run;
  final TextStyle style;
  @override
  State<CountingTimer> createState() => _CountingTimerState();
}

class _CountingTimerState extends State<CountingTimer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.run)..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static String fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Text(
            fmt(widget.from +
                Duration(
                    milliseconds:
                        (widget.run.inMilliseconds * _c.value).round())),
            style: widget.style),
      );
}

/// Welcome: a recording pill above a finished note.
class WelcomeVisual extends StatelessWidget {
  const WelcomeVisual({super.key});
  @override
  Widget build(BuildContext context) {
    final demo = DemoNote.forUse(null);
    return Stack(clipBehavior: Clip.none, children: [
      Padding(
        padding: const EdgeInsets.only(top: 34),
        child: Reveal(
          delay: const Duration(milliseconds: 250),
          child: MockCard(
            padding: const EdgeInsets.fromLTRB(18, 34, 18, 18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(demo.title,
                  style: LnText.noteTitle.copyWith(fontSize: 20, height: 1.2)),
              const SizedBox(height: 4),
              Text(demo.meta, style: LnText.monoSmall),
              const SizedBox(height: 12),
              Text(demo.lead,
                  style: LnText.summaryLead.copyWith(fontSize: 15, height: 1.45)),
              const SizedBox(height: 12),
              for (final a in demo.actions.take(2))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _ActionRow(a),
                ),
            ]),
          ),
        ),
      ),
      const Positioned(
        top: 12,
        left: 18,
        child: Reveal(child: RecordingPill(from: Duration(hours: 1, minutes: 51, seconds: 58))),
      ),
    ]);
  }
}

class RecordingPill extends StatelessWidget {
  const RecordingPill({super.key, required this.from});
  final Duration from;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
        decoration: BoxDecoration(
            color: LnColors.night,
            borderRadius: BorderRadius.circular(LnRadius.pill),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 6))
            ]),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                  color: LnColors.signal, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text('Recording',
              style: _w(LnText.chip.copyWith(color: LnColors.nightText, fontSize: 13), 600)),
          const SizedBox(width: 8),
          CountingTimer(
              from: from,
              style: LnText.monoSmall
                  .copyWith(color: LnColors.nightText2, fontSize: 13)),
        ]),
      );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow(this.a);
  final DemoAction a;
  @override
  Widget build(BuildContext context) => Row(children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: LnColors.ink3, width: 1.4)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(a.text, style: LnText.bullet.copyWith(fontSize: 14))),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
              color: LnColors.fill, borderRadius: BorderRadius.circular(LnRadius.chip)),
          child: Text(a.owner, style: LnText.chip.copyWith(fontSize: 11)),
        ),
      ]);
}

/// Hours, not minutes: the dark recording screen with the screen locked.
class HoursVisual extends StatelessWidget {
  const HoursVisual({super.key});
  @override
  Widget build(BuildContext context) => Reveal(
        child: MockCard(
          color: LnColors.night,
          border: null,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const LnIcon(LnIcons.lock, size: 14, color: LnColors.nightText3),
              const SizedBox(width: 6),
              Text('Screen locked · still recording',
                  style: LnText.chip.copyWith(color: LnColors.nightText3)),
            ]),
            const SizedBox(height: 18),
            Center(
              child: CountingTimer(
                  from: const Duration(hours: 2, minutes: 59, seconds: 55),
                  run: const Duration(seconds: 6),
                  style: LnText.timer.copyWith(
                      color: LnColors.nightText, fontSize: 46, height: 1)),
            ),
            const SizedBox(height: 18),
            const WaveBars(color: LnColors.recordingPillText, height: 40),
            const SizedBox(height: 18),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in const ['Part 1 saved', 'Part 2 saved', 'Part 3 …'])
                Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                        color: p.endsWith('…')
                            ? LnColors.recordingPillBg
                            : LnColors.savedPillBg,
                        borderRadius: BorderRadius.circular(LnRadius.pill)),
                    child: Text(p,
                        style: LnText.chip.copyWith(
                            fontSize: 11,
                            color: p.endsWith('…')
                                ? LnColors.recordingPillText
                                : LnColors.savedPillText)),
                  ),
            ]),
          ]),
        ),
      );
}

/// The summary of the sample note, section by section.
class SummaryVisual extends StatelessWidget {
  const SummaryVisual({super.key, required this.demo});
  final DemoNote demo;
  @override
  Widget build(BuildContext context) {
    Duration d(int i) => Duration(milliseconds: 150 + i * 220);
    return MockCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Reveal(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(demo.title,
                style: LnText.noteTitle.copyWith(fontSize: 19, height: 1.2)),
            const SizedBox(height: 3),
            Text(demo.meta, style: LnText.monoSmall),
          ]),
        ),
        const SizedBox(height: 12),
        Reveal(
            delay: d(1),
            child: Text(demo.lead,
                style: LnText.summaryLead.copyWith(fontSize: 15, height: 1.42))),
        const SizedBox(height: 12),
        Reveal(
          delay: d(2),
          child: _Section(
            label: 'Key points',
            child: Column(children: [
              for (final p in demo.points.take(2)) _Bullet(p),
            ]),
          ),
        ),
        Reveal(
          delay: d(3),
          child: _Section(
            label: demo.decisionsLabel,
            child: Column(children: [for (final p in demo.decisions) _Bullet(p)]),
          ),
        ),
        Reveal(
          delay: d(4),
          child: _Section(
            label: demo.actionsLabel,
            last: true,
            child: Column(children: [
              for (final a in demo.actions)
                Padding(
                    padding: const EdgeInsets.only(bottom: 6), child: _ActionRow(a)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child, this.last = false});
  final String label;
  final Widget child;
  final bool last;
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LnOverline(label),
          const SizedBox(height: 6),
          child,
        ]),
      );
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 8, right: 9),
            child: Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                    color: LnColors.ink, shape: BoxShape.circle)),
          ),
          Expanded(child: Text(text, style: LnText.bullet.copyWith(fontSize: 14))),
        ]),
      );
}

/// Transcript turns with speaker names and times.
class TranscriptVisual extends StatelessWidget {
  const TranscriptVisual({super.key, required this.demo});
  final DemoNote demo;
  @override
  Widget build(BuildContext context) => MockCard(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Column(children: [
          for (var i = 0; i < demo.turns.length; i++)
            Reveal(
              delay: Duration(milliseconds: 120 + i * 320),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  LnSpeakerAvatar(
                      name: demo.turns[i].speaker,
                      colorIndex: demo.turns[i].color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text(demo.turns[i].speaker,
                                style: LnText.speakerName.copyWith(
                                    color: LnSpeakerColors.of(demo.turns[i].color))),
                            const SizedBox(width: 8),
                            Text(demo.turns[i].time, style: LnText.monoSmall),
                          ]),
                          const SizedBox(height: 3),
                          Text(demo.turns[i].text, style: LnText.turn),
                        ]),
                  ),
                ]),
              ),
            ),
        ]),
      );
}

/// A question and its answer, with where in the recording it came from.
class AskVisual extends StatelessWidget {
  const AskVisual({super.key, required this.demo});
  final DemoNote demo;
  @override
  Widget build(BuildContext context) => Column(children: [
        Reveal(
          child: Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 270),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                color: LnColors.ink,
                borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(4)),
              ),
              child: Text(demo.question,
                  style: LnText.base.copyWith(color: LnColors.card)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Reveal(
          delay: const Duration(milliseconds: 700),
          child: MockCard(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const LnIcon(LnIcons.sparkle, size: 14, color: LnColors.ink2),
                const SizedBox(width: 6),
                Text('Answer from your note', style: LnText.caption),
              ]),
              const SizedBox(height: 8),
              Text(demo.answer, style: LnText.turn),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                    color: LnColors.highlight,
                    borderRadius: BorderRadius.circular(LnRadius.chip)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const LnIcon(LnIcons.play, size: 11, color: LnColors.attention),
                  const SizedBox(width: 5),
                  Text('Heard at ${demo.answerAt}',
                      style: LnText.chip.copyWith(color: LnColors.attention)),
                ]),
              ),
            ]),
          ),
        ),
      ]);
}

/// A row with a round icon and two lines (trust screen, paywall).
class IconLine extends StatelessWidget {
  const IconLine(
      {super.key, required this.icon, required this.title, required this.text});
  final LnIcons icon;
  final String title;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration:
                const BoxDecoration(color: LnColors.card, shape: BoxShape.circle),
            child: LnIcon(icon, size: 17),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: LnText.rowTitleSmall),
              const SizedBox(height: 2),
              Text(text, style: LnText.meta.copyWith(fontSize: 14, height: 1.4)),
            ]),
          ),
        ]),
      );
}

/// "Setting up": each line spins, then gets a check, one after another.
class SetupChecklist extends StatefulWidget {
  const SetupChecklist({super.key, required this.items});
  final List<String> items;
  @override
  State<SetupChecklist> createState() => _SetupChecklistState();
}

class _SetupChecklistState extends State<SetupChecklist>
    with SingleTickerProviderStateMixin {
  static const _step = 650;
  late final AnimationController _c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _step * widget.items.length + 200))
    ..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final ms = _c.value * _c.duration!.inMilliseconds;
          return MockCard(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(children: [
              for (var i = 0; i < widget.items.length; i++)
                _CheckLine(
                  text: widget.items[i],
                  state: ms >= (i + 1) * _step
                      ? 2
                      : ms >= i * _step
                          ? 1
                          : 0,
                  last: i == widget.items.length - 1,
                ),
            ]),
          );
        },
      );
}

class _CheckLine extends StatelessWidget {
  const _CheckLine({required this.text, required this.state, required this.last});
  final String text;

  /// 0 waiting, 1 working, 2 done.
  final int state;
  final bool last;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
            border: last
                ? null
                : const Border(bottom: BorderSide(color: LnColors.line))),
        child: Row(children: [
          SizedBox(
            width: 22,
            height: 22,
            child: switch (state) {
              2 => Container(
                  decoration: const BoxDecoration(
                      color: LnColors.saved, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: const LnIcon(LnIcons.check, size: 12, color: LnColors.card)),
              1 => const Padding(
                  padding: EdgeInsets.all(3),
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: LnColors.ink, value: 0.7)),
              _ => Container(
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: LnColors.line, width: 1.5))),
            },
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: LnText.rowLabel.copyWith(
                    color: state == 0 ? LnColors.ink3 : LnColors.ink)),
          ),
        ]),
      );
}
