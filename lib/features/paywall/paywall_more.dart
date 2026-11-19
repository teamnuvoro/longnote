import 'package:flutter/material.dart';

import '../../ui/widgets.dart';
import '../common/widgets.dart';

/// The longer part of the paywall, below the plans: what Pro includes, how
/// it works, honest billing, and common questions. Every claim here is true
/// of the app today (keep it that way when features change).
class PaywallMore extends StatelessWidget {
  const PaywallMore({super.key, this.onFaqOpened, this.firstRun = true});

  /// First-run paywall: the free first recording is still unused, so the
  /// "Can I try it without paying?" answer is true only here.
  final bool firstRun;

  /// Called with the question's id when a question is opened (analytics).
  final void Function(String id)? onFaqOpened;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Heading('Everything in Pro'),
          const _FeatureGrid(),
          const SizedBox(height: 28),
          const _Heading('How it works'),
          const _HowItWorks(),
          const SizedBox(height: 28),
          const _HonestBilling(),
          const SizedBox(height: 28),
          const _Heading('Questions'),
          _Faq(onOpened: onFaqOpened, firstRun: firstRun),
          const SizedBox(height: 12),
        ],
      );
}

/// "What you get ⌄" under the plans: tells people there is more below.
class PaywallMoreHint extends StatelessWidget {
  const PaywallMoreHint({super.key, required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Center(
        child: LnPressable(
          onPressed: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('See everything you get',
                  style: LnText.caption.copyWith(color: LnColors.ink2)),
              const SizedBox(width: 4),
              const LnIcon(LnIcons.chevronDown, size: 14, color: LnColors.ink2),
            ]),
          ),
        ),
      );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(text,
            style: LnText.noteTitle.copyWith(fontSize: 22, height: 1.2)),
      );
}

class _FeatureGrid extends StatelessWidget {
  const _FeatureGrid();

  static const _items = [
    (LnIcons.infinity, 'Unlimited recordings', 'Record as often as you like.'),
    (LnIcons.mic, 'Hours per recording', 'No time limit, screen locked or not.'),
    (LnIcons.users, 'Who said what', 'Speaker names and times.'),
    (LnIcons.template, '9 summary styles', 'Meetings, lectures, calls and more.'),
    (LnIcons.tabAsk, 'Ask your notes', 'Answers with the moment it was said.'),
    (LnIcons.globe, '60+ languages', 'Including Hinglish, or auto-detect.'),
    (LnIcons.tabImport, 'Import audio', 'Voice memos and files you already have.'),
    (LnIcons.share, 'Share anywhere', 'PDF, text or the audio itself.'),
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth - 10) / 2;
        return Wrap(spacing: 10, runSpacing: 10, children: [
          for (final (icon, title, text) in _items)
            SizedBox(
              width: w,
              child: LnCard(
                padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LnIcon(icon, size: 20),
                      const SizedBox(height: 10),
                      Text(title, style: LnText.rowTitleSmall.copyWith(fontSize: 14)),
                      const SizedBox(height: 2),
                      Text(text,
                          style: LnText.meta.copyWith(fontSize: 12, height: 1.35)),
                    ]),
              ),
            ),
        ]);
      });
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();
  static const _steps = [
    ('Tap Record', 'Put the phone down and forget about it. Lock it if you like.'),
    ('Get your notes', 'A transcript and a summary, a few minutes after you stop.'),
    ('Ask and share', 'Ask about any detail, then send the notes to anyone.'),
  ];
  @override
  Widget build(BuildContext context) => LnCard(
        child: Column(children: [
          for (var i = 0; i < _steps.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == _steps.length - 1 ? 0 : 14),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                      color: LnColors.ink, shape: BoxShape.circle),
                  child: Text('${i + 1}',
                      style: LnText.smallButton.copyWith(color: LnColors.card)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_steps[i].$1, style: LnText.rowTitleSmall),
                        const SizedBox(height: 2),
                        Text(_steps[i].$2,
                            style: LnText.meta.copyWith(height: 1.4)),
                      ]),
                ),
              ]),
            ),
        ]),
      );
}

class _HonestBilling extends StatelessWidget {
  const _HonestBilling();
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: LnColors.savedTint,
            borderRadius: BorderRadius.circular(LnRadius.card)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const LnIcon(LnIcons.bell, size: 20, color: LnColors.saved),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('No surprise charges',
                  style: LnText.rowTitleSmall.copyWith(color: LnColors.saved)),
              const SizedBox(height: 3),
              Text(
                  'With notifications on, we remind you a day before your trial ends. Cancel any time in your iPhone Settings.',
                  style: LnText.meta.copyWith(color: LnColors.ink, height: 1.4)),
            ]),
          ),
        ]),
      );
}

class _Faq extends StatefulWidget {
  const _Faq({this.onOpened, required this.firstRun});
  final void Function(String id)? onOpened;
  final bool firstRun;
  @override
  State<_Faq> createState() => _FaqState();
}

class _FaqState extends State<_Faq> {
  static const _all = [
    (
      'length',
      'Is there a limit on recording time?',
      'No. Record for minutes or for hours. Longnote saves the audio in parts as it records, so even a very long recording is safe.'
    ),
    (
      'locked',
      'What if my screen locks or I get a call?',
      'Recording keeps going with the screen locked or while you use other apps. A phone call pauses it; everything before the call is already saved.'
    ),
    (
      'privacy',
      'Where does my audio go?',
      'It stays on your phone. To write the transcript it is sent to our speech-to-text provider and deleted from their servers and ours as soon as the transcript is back. Or choose “On this phone” in Settings › Transcription and nothing leaves your phone.'
    ),
    (
      'cancel',
      'How do I cancel?',
      'In iPhone Settings › your name › Subscriptions, any time. Cancel during the free trial and you pay nothing.'
    ),
    (
      'free',
      'Can I try it without paying?',
      'Yes. Close this screen and your first recording is free, with its full transcript and summary.'
    ),
    (
      'languages',
      'Which languages does it understand?',
      'More than 60, including Hinglish. It can also detect the language for you.'
    ),
  ];
  final _open = <String>{};

  List<(String, String, String)> get _qs => [
        for (final q in _all)
          if (q.$1 != 'free' || widget.firstRun) q,
      ];

  @override
  Widget build(BuildContext context) => LnCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: Column(children: [
          for (var i = 0; i < _qs.length; i++)
            _FaqItem(
              key: ValueKey('faq-${_qs[i].$1}'),
              q: _qs[i].$2,
              a: _qs[i].$3,
              open: _open.contains(_qs[i].$1),
              last: i == _qs.length - 1,
              onTap: () {
                final id = _qs[i].$1;
                setState(() => _open.contains(id) ? _open.remove(id) : _open.add(id));
                if (_open.contains(id)) widget.onOpened?.call(id);
              },
            ),
        ]),
      );
}

class _FaqItem extends StatelessWidget {
  const _FaqItem({
    super.key,
    required this.q,
    required this.a,
    required this.open,
    required this.last,
    required this.onTap,
  });
  final String q;
  final String a;
  final bool open;
  final bool last;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
            border: last
                ? null
                : const Border(bottom: BorderSide(color: LnColors.line))),
        child: Semantics(
          button: true,
          expanded: open,
          child: LnPressable(
            onPressed: onTap,
            pressedOpacity: 0.7,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(child: Text(q, style: LnText.rowLabel)),
                      AnimatedRotation(
                        turns: open ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: const LnIcon(LnIcons.chevronDown,
                            size: 16, color: LnColors.ink3),
                      ),
                    ]),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: open
                          ? Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(a,
                                  style: LnText.meta
                                      .copyWith(fontSize: 14, height: 1.45)),
                            )
                          : const SizedBox(width: double.infinity),
                    ),
                  ]),
            ),
          ),
        ),
      );
}
