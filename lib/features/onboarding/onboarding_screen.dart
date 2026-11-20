import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../app_services.dart';
import '../../core/analytics/analytics.dart';
import '../../core/summary/summary_style.dart';
import '../../ui/widgets.dart';
import '../common/widgets.dart';
import 'onboarding_content.dart';
import 'onboarding_visuals.dart';

/// First run, US-style: two short questions, five screens that show what
/// the app does (with a sample note that matches the first answer), how
/// audio is handled, a "setting up" moment, the microphone, then the
/// paywall. No sign-in, no account (owner, 19 Nov 2026: login comes later).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  /// The main button (its label changes per page).
  static const nextKey = ValueKey('onboarding-next');

  /// Saved answers (for a later default summary style).
  static const kvUses = 'onboarding_uses';
  static const kvLength = 'onboarding_length';

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { welcome, uses, length, hours, summary, speakers, ask, privacy, ready, mic }

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;
  String? _micMessage;
  final _uses = <RecordUse>[];
  RecordLength? _length;

  /// Checking the App Store for an existing plan (up to a few seconds).
  bool _finishing = false;

  static const _steps = _Step.values;
  _Step get _step => _steps[_page];

  AppServices get _s => context.read<AppServices>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _logStep());
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _logStep({bool back = false}) {
    if (!mounted) return;
    _s.analytics.log(AnalyticsEvent.onboardingStep, props: {
      'step': _step.name,
      'index': _page,
      'dir': back ? 'back' : 'forward',
    });
  }

  /// The style the first answer sets as the default (null: none).
  SummaryStyle? get _style => _uses.isEmpty ? null : _uses.first.style;

  Future<void> _finish() async {
    if (_finishing) return;
    final s = _s;
    setState(() => _finishing = true);
    await s.kv.setBool(AppServices.kvOnboardingDone, true);
    await s.kv.set(OnboardingScreen.kvUses, _uses.map((u) => u.id).join(','));
    await s.kv.set(OnboardingScreen.kvLength, _length?.id);
    // The first answer picks the default summary style ("ready" says so).
    final style = _style;
    if (style != null) {
      await s.settings.setDefaultStyle(style);
      s.analytics.log(AnalyticsEvent.summaryStyleChanged,
          props: {'style': style.id, 'from': 'onboarding'});
    }
    // A fresh install can learn about an existing plan a few seconds late
    // (StoreKit syncs after install): ask again before showing the paywall.
    if (!s.billing.entitlement.value.isActive) {
      await s.billing
          .refresh()
          .timeout(const Duration(seconds: 8), onTimeout: () {})
          .catchError((Object e) => debugPrint('onboarding refresh: $e'));
    }
    // No "Allow tracking?" prompt (owner, 18 Nov 2026): Meta runs without
    // the advertising ID.
    // Never let analytics hold the user here (a stuck native SDK call).
    await s.analytics
        .log(AnalyticsEvent.onboardingCompleted, props: {
          'mic': _micMessage == null ? 'allowed' : 'denied',
          // One flag per answer (remote props only allow short codes).
          for (final u in RecordUse.values) 'use_${u.id}': _uses.contains(u),
          'first_use': _uses.isEmpty ? 'none' : _uses.first.id,
          'length': _length?.id ?? 'skipped',
        })
        .timeout(const Duration(seconds: 2), onTimeout: () {})
        .catchError((Object e) => debugPrint('onboarding log: $e'));
    if (!mounted) return;
    setState(() => _finishing = false);
    if (s.billing.entitlement.value.isActive) {
      // Already subscribed (reinstall / restored): no paywall.
      await s.kv.setBool(AppServices.kvFirstPaywallSeen, true);
      if (mounted) context.goNamed(R.notes);
      return;
    }
    // onboarding -> paywall (once) -> Notes
    context.goNamed(R.paywall, queryParameters: {'first': '1'});
  }

  /// The iOS microphone question is open (a second tap must not ask again).
  bool _asking = false;

  Future<void> _askMic() async {
    if (_asking || _finishing) return;
    _asking = true;
    // The recorder's own microphone source (a fake one in tests).
    final src = _s.recorder.sourceFactory();
    bool ok;
    try {
      ok = await src.hasPermission(request: true);
    } catch (_) {
      ok = false;
    } finally {
      src.dispose();
      _asking = false;
    }
    if (!mounted) return;
    _s.analytics.log(AnalyticsEvent.micPermission,
        props: {'result': ok ? 'allowed' : 'denied', 'from': 'onboarding'});
    if (ok) {
      await _finish();
    } else {
      setState(() => _micMessage =
          'No problem. You can turn the microphone on later in iPhone Settings > Longnote. Recording needs it.');
    }
  }

  void _go(int page) {
    if (page < 0 || page >= _steps.length || _finishing) return;
    final back = page < _page;
    setState(() => _page = page);
    _pages.animateToPage(page,
        duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
    _logStep(back: back);
  }

  void _next() {
    if (_step == _Step.mic) {
      _micMessage == null ? _askMic() : _finish();
      return;
    }
    _go(_page + 1);
  }

  String get _cta => switch (_step) {
        _Step.welcome => 'Get started',
        _Step.ready => 'Continue',
        _Step.mic => _micMessage == null ? 'Allow microphone' : 'Continue',
        _ => 'Continue',
      };

  DemoNote get _demo => DemoNote.forUse(_uses.isEmpty ? null : _uses.first);

  Widget _pageFor(_Step step) => switch (step) {
        _Step.welcome => const _Welcome(),
        _Step.uses => _Question(
            title: 'What will you record?',
            body: 'Pick all that apply. We’ll show you what your notes look like.',
            child: Column(children: [
              for (final u in RecordUse.values)
                _Choice(
                  key: ValueKey('use-${u.id}'),
                  icon: u.icon,
                  label: u.label,
                  selected: _uses.contains(u),
                  multi: true,
                  onTap: () => setState(
                      () => _uses.contains(u) ? _uses.remove(u) : _uses.add(u)),
                ),
            ]),
          ),
        _Step.length => _Question(
            title: 'How long do they usually run?',
            body: 'Longnote records for hours, whatever you pick.',
            child: Column(children: [
              for (final l in RecordLength.values)
                _Choice(
                  key: ValueKey('length-${l.id}'),
                  label: l.label,
                  selected: _length == l,
                  onTap: () => setState(() => _length = l),
                ),
            ]),
          ),
        _Step.hours => _Pitch(
            overline: 'Record',
            title: _length == RecordLength.longer || _length == RecordLength.twoHours
                ? 'Two hours? Four?\nKeep going.'
                : 'Hours, not minutes.',
            body:
                'No minute counter: up to 5 hours in one recording is transcribed. Lock your phone or switch apps: Longnote keeps recording and saves as it goes, so a phone call or a dead battery never costs you what you already recorded.',
            visual: const HoursVisual(),
          ),
        _Step.summary => _Pitch(
            overline: 'Summarize',
            title: 'Notes that write themselves.',
            body:
                'A clear summary made for ${_demo.styleWord}, ready a few minutes after you stop. The main points first, then the details that matter.',
            visual: SummaryVisual(demo: _demo),
          ),
        _Step.speakers => _Pitch(
            overline: 'Transcribe',
            title: 'Every word, and who said it.',
            body:
                'A full transcript with speaker names and times, in 60+ languages. Tap any line to hear it again.',
            visual: TranscriptVisual(demo: _demo),
          ),
        _Step.ask => _Pitch(
            overline: 'Ask',
            title: 'Ask your notes anything.',
            body:
                'Forgot a number or who promised what? Ask in plain words and get the answer, with the moment it was said.',
            visual: AskVisual(demo: _demo),
          ),
        _Step.privacy => const _Privacy(),
        _Step.ready => _Ready(
            personal: _style != null,
            items: [
              _style == null
                  ? '9 summary styles, from meetings to lectures'
                  : 'Summaries set up for ${_uses.first.short}',
              'Up to 5 hours per recording',
              'Speaker names in transcripts',
              'Ask about any note',
            ],
          ),
        _Step.mic => _Mic(message: _micMessage),
      };

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _page > 0 && !_finishing) _go(_page - 1);
      },
      child: LnScaffold(
        backgroundColor: LnColors.paper,
        body: SafeArea(
          child: Column(children: [
            _TopBar(
              page: _page,
              count: _steps.length,
              onBack: _page == 0 || _finishing ? null : () => _go(_page - 1),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final st in _steps)
                    KeyedSubtree(key: ValueKey('onb-${st.name}'), child: _pageFor(st)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 12),
              child: Column(children: [
                LnPrimaryButton(
                  key: OnboardingScreen.nextKey,
                  label: _cta,
                  busy: _finishing,
                  onPressed: _next,
                ),
                if (_step == _Step.welcome) ...[
                  const SizedBox(height: 10),
                  Text('No account needed. Takes about a minute.',
                      style: LnText.meta.copyWith(fontSize: 12)),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.page, required this.count, this.onBack});
  final int page;
  final int count;
  final VoidCallback? onBack;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 48,
        child: Row(children: [
          SizedBox(
            width: 52,
            child: page == 0
                ? null
                : LnIconButton(
                    icon: LnIcons.chevronLeft,
                    size: 36,
                    iconSize: 20,
                    color: LnColors.ink2,
                    semanticLabel: 'Back',
                    onPressed: onBack,
                  ),
          ),
          Expanded(
            child: page == 0
                ? const SizedBox()
                : ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: page / (count - 1)),
                      duration: const Duration(milliseconds: 380),
                      curve: Curves.easeOutCubic,
                      builder: (context, v, _) => LinearProgressIndicator(
                        value: v,
                        minHeight: 4,
                        backgroundColor: LnColors.fill,
                        color: LnColors.ink,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 52),
        ]),
      );
}

/// Shared page layout: text on top, then the visual.
class _PageBody extends StatelessWidget {
  const _PageBody({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}

TextStyle get _title =>
    LnText.largeTitle.copyWith(fontSize: 32, height: 1.12, letterSpacing: -0.4);

class _Welcome extends StatelessWidget {
  const _Welcome();
  @override
  Widget build(BuildContext context) => _PageBody(children: [
        const SizedBox(height: 8),
        const WelcomeVisual(),
        const SizedBox(height: 34),
        Reveal(
          delay: const Duration(milliseconds: 500),
          child: Text('Every word of every meeting.',
              style: _title.copyWith(fontSize: 36)),
        ),
        const SizedBox(height: 12),
        Reveal(
          delay: const Duration(milliseconds: 650),
          child: Text(
              'Record for hours. Get a transcript, a clear summary and answers to any question, without typing a word.',
              style: LnText.body.copyWith(color: LnColors.ink2, height: 1.45)),
        ),
      ]);
}

class _Question extends StatelessWidget {
  const _Question({required this.title, required this.body, required this.child});
  final String title;
  final String body;
  final Widget child;
  @override
  Widget build(BuildContext context) => _PageBody(children: [
        const SizedBox(height: 8),
        Text(title, style: _title),
        const SizedBox(height: 8),
        Text(body, style: LnText.body.copyWith(color: LnColors.ink2)),
        const SizedBox(height: 22),
        child,
      ]);
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.multi = false,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final LnIcons? icon;
  final bool multi;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Semantics(
          selected: selected,
          button: true,
          child: LnPressable(
            onPressed: onTap,
            pressedOpacity: 0.8,
            child: LnCard(
              selected: selected,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              child: Row(children: [
                if (icon != null) ...[
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: selected ? LnColors.ink : LnColors.fill,
                        borderRadius: BorderRadius.circular(10)),
                    child: LnIcon(icon!,
                        size: 17, color: selected ? LnColors.card : LnColors.ink),
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(child: Text(label, style: LnText.rowTitleSmall)),
                multi
                    ? AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 22,
                        height: 22,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: selected ? LnColors.ink : null,
                          borderRadius: BorderRadius.circular(6),
                          border: selected
                              ? null
                              : Border.all(color: LnColors.ink3, width: 1.5),
                        ),
                        child: selected
                            ? const LnIcon(LnIcons.check,
                                size: 13, color: LnColors.card)
                            : null,
                      )
                    : LnRadioMark(selected: selected),
              ]),
            ),
          ),
        ),
      );
}

class _Pitch extends StatelessWidget {
  const _Pitch(
      {required this.overline,
      required this.title,
      required this.body,
      required this.visual});
  final String overline;
  final String title;
  final String body;
  final Widget visual;
  @override
  Widget build(BuildContext context) => _PageBody(children: [
        const SizedBox(height: 4),
        LnOverline(overline),
        const SizedBox(height: 8),
        Text(title, style: _title),
        const SizedBox(height: 10),
        Text(body,
            style: LnText.body.copyWith(color: LnColors.ink2, height: 1.45)),
        const SizedBox(height: 24),
        visual,
      ]);
}

class _Privacy extends StatelessWidget {
  const _Privacy();
  @override
  Widget build(BuildContext context) => _PageBody(children: [
        const SizedBox(height: 4),
        const LnOverline('Your audio'),
        const SizedBox(height: 8),
        Text('Where your audio goes', style: _title),
        const SizedBox(height: 10),
        Text('Plainly, before you start.',
            style: LnText.body.copyWith(color: LnColors.ink2)),
        const SizedBox(height: 22),
        const Reveal(
          child: IconLine(
            icon: LnIcons.shield,
            title: 'Saved on this phone as you record',
            text: 'A locked screen or a closed app never loses it.',
          ),
        ),
        const Reveal(
          delay: Duration(milliseconds: 150),
          child: IconLine(
            icon: LnIcons.cloud,
            title: 'Sent only to make the transcript',
            text:
                'Longnote sends the audio to our speech-to-text provider. It is deleted from their servers and ours as soon as the transcript is back; the original stays on your phone until you delete it.',
          ),
        ),
        const Reveal(
          delay: Duration(milliseconds: 300),
          child: IconLine(
            icon: LnIcons.cloudOff,
            title: 'Or keep everything on your phone',
            text:
                'Choose “On this phone” in Settings › Transcription. It is slower and has no speaker labels.',
          ),
        ),
        const Reveal(
          delay: Duration(milliseconds: 450),
          child: IconLine(
            icon: LnIcons.lock,
            title: 'No account. No ads.',
            text: 'Please ask people before you record them.',
          ),
        ),
      ]);
}

class _Ready extends StatelessWidget {
  const _Ready({required this.items, required this.personal});
  final List<String> items;
  final bool personal;
  @override
  Widget build(BuildContext context) => _PageBody(children: [
        const SizedBox(height: 4),
        const LnOverline('All set'),
        const SizedBox(height: 8),
        Text('Your Longnote is ready.', style: _title),
        const SizedBox(height: 10),
        Text(
            personal
                ? 'Set up for the way you record. Change it any time in Settings.'
                : 'Everything you need to start recording.',
            style: LnText.body.copyWith(color: LnColors.ink2)),
        const SizedBox(height: 24),
        SetupChecklist(items: items),
      ]);
}

class _Mic extends StatelessWidget {
  const _Mic({this.message});
  final String? message;
  @override
  Widget build(BuildContext context) => _PageBody(children: [
        const SizedBox(height: 28),
        Center(
          child: Reveal(
            child: Container(
              width: 112,
              height: 112,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: LnColors.card,
                shape: BoxShape.circle,
                border: Border.all(color: LnColors.line),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 24,
                      offset: Offset(0, 10))
                ],
              ),
              child: const LnIcon(LnIcons.mic, size: 44),
            ),
          ),
        ),
        const SizedBox(height: 32),
        Text('Allow the microphone', style: _title),
        const SizedBox(height: 10),
        Text(
            'Longnote needs the microphone to record. It only listens while you are recording, and the red indicator shows when.',
            style: LnText.body.copyWith(color: LnColors.ink2, height: 1.45)),
        if (message != null) ...[
          const SizedBox(height: 16),
          Text(message!,
              style: LnText.body.copyWith(color: LnColors.destructiveText)),
        ],
      ]);
}
