import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../app_services.dart';
import '../../core/analytics/analytics.dart';
import '../../core/billing/billing_service.dart';
import '../../ui/widgets.dart';
import '../common/dates.dart';
import '../common/external.dart';
import '../common/links.dart';
import '../common/screen_clock.dart';
import '../common/widgets.dart';
import 'trial_copy.dart';

/// A1 Paywall (Figma 5:167). Honest: yearly preselected, the trial timeline
/// with real dates (today, the reminder 26 h before the end, the charge
/// date), the exact price and date above the button, how to cancel.
/// Real App Store billing on iPhone; with [FakeBillingService] (tests, QA)
/// a chip says purchases are simulated.
///
/// After a trial starts, A2 (trial started) asks for the reminder permission;
/// then the paywall closes. Pops with `true` when the user now has access,
/// or calls [onDone] on the first run.
class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key, this.onDone, this.placement = 'second_recording'});

  /// First run (onboarding -> paywall -> app): called instead of popping,
  /// with true when the user subscribed / started a trial.
  final void Function(BuildContext context, bool subscribed)? onDone;

  /// Analytics placement: 'first_run' or 'second_recording'.
  final String placement;

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  // Store prices (user's currency) if already loaded at launch.
  late List<Plan> _plans = [
    planForId(annualPlan.id),
    planForId(monthlyPlan.id),
  ];
  late Plan _selected = _plans.first;
  bool _busy = false;
  bool _closed = false;

  AppServices get _s => context.read<AppServices>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final s = _s;
      await s.analytics.log(AnalyticsEvent.paywallViewed,
          props: {'placement': widget.placement});
      final plans = await s.billing.loadPlans();
      if (!mounted || plans.isEmpty) return;
      setState(() {
        _plans = plans;
        _selected = plans.firstWhere((p) => p.period == PlanPeriod.year,
            orElse: () => plans.first);
      });
    });
  }

  Plan? _plan(PlanPeriod p) {
    for (final x in _plans) {
      if (x.period == p) return x;
    }
    return null;
  }

  Future<void> _buy() async {
    final plan = _selected;
    final s = _s;
    setState(() => _busy = true);
    final res = await s.billing.purchase(plan);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!res.success) {
      showNote(context, res.error ?? 'Purchase did not complete. Nothing was charged.');
      return;
    }
    // Apple's answer decides (not the eligibility guess shown before).
    if (res.startedTrial) {
      final ends = s.billing.entitlement.value.trialEndsAt!;
      await s.analytics.log(AnalyticsEvent.trialStarted,
          props: {'plan': plan.id, 'trial_ends_at': ends.toIso8601String()});
      if (!mounted) return;
      // A2: the reminder permission is asked there, with its reason.
      await context.pushNamed(R.trialStarted);
    }
    if (mounted) _close(true);
  }

  Future<void> _restore() async {
    final s = _s;
    final r = await s.billing.restore();
    if (!mounted) return;
    if (s.billing.entitlement.value.isActive) {
      _close(true);
    } else {
      showNote(
          context,
          r == RestoreResult.failed
              ? 'Couldn’t reach the App Store. Check your connection and try again.'
              : 'No purchase found to restore on this Apple ID.');
    }
  }

  void _close(bool subscribed) {
    if (_closed) return;
    _closed = true;
    final done = widget.onDone;
    if (done != null) {
      done(context, subscribed);
    } else {
      Navigator.of(context).pop(subscribed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trial = context.read<AppServices>().billing.trialEligible;
    final now = screenNow();
    final plan = _selected;
    final yearly = _plan(PlanPeriod.year);
    final monthly = _plan(PlanPeriod.month);
    return LnScaffold(
      backgroundColor: LnColors.paper,
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 4, 20, 0),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      if (_s.billing is FakeBillingService)
                        const LnChip('Test build: purchases are simulated'),
                      const Spacer(),
                      LnIconButton(
                        icon: LnIcons.x,
                        size: 32,
                        iconSize: 16,
                        color: LnColors.ink2,
                        semanticLabel: 'Close',
                        onPressed: () => _close(false),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 300,
                              child: Text('Every word of every meeting.',
                                  style: LnText.largeTitle
                                      .copyWith(fontSize: 31, height: 36 / 31)),
                            ),
                            const SizedBox(height: 6),
                            Text(
                                trial
                                    ? 'Try everything free for ${plan.trialDays} days.'
                                    : 'Keep recording, as long as you want.',
                                style: LnText.body
                                    .copyWith(color: LnColors.ink2, height: null)),
                            const SizedBox(height: 20),
                            const _Feature(LnIcons.infinity,
                                'Record for hours. No minute counter.'),
                            const _Feature(
                                LnIcons.users, 'Every word, and who said it'),
                            const _Feature(LnIcons.list,
                                'Summaries with decisions and action items'),
                            const _Feature(
                                LnIcons.tabAsk, 'Ask anything about a note'),
                            const _Feature(LnIcons.shield,
                                'Audio saved on your phone as you record',
                                last: true),
                            const SizedBox(height: 22),
                            Text('Longnote Pro · auto-renewing subscription',
                                key: const ValueKey('paywall-product-name'),
                                style: LnText.caption),
                            const SizedBox(height: 8),
                            _Timeline(plan: plan, trial: trial, now: now),
                            const SizedBox(height: 14),
                            Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (yearly != null)
                                    Expanded(
                                      child: _PlanCard(
                                        name: 'Yearly',
                                        price: yearly.priceLabel,
                                        sub: monthlyEquivalent(yearly),
                                        tag: monthly == null
                                            ? null
                                            : 'Save ${yearlySavingPercent(yearly, monthly)}%',
                                        selected: plan == yearly,
                                        onTap: () =>
                                            setState(() => _selected = yearly),
                                      ),
                                    ),
                                  if (yearly != null && monthly != null)
                                    const SizedBox(width: 10),
                                  if (monthly != null)
                                    Expanded(
                                      child: _PlanCard(
                                        name: 'Monthly',
                                        price: monthly.priceLabel,
                                        sub: 'per month',
                                        selected: plan == monthly,
                                        onTap: () =>
                                            setState(() => _selected = monthly),
                                      ),
                                    ),
                                ]),
                            const SizedBox(height: 16),
                          ]),
                    ),
                  ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 5),
            child: Column(children: [
              LnPrimaryButton(
                label: trial ? 'Start free trial' : 'Subscribe',
                busy: _busy,
                onPressed: _buy,
              ),
              const SizedBox(height: 10),
              Text(priceLine(plan, trial: trial, now: now),
                  key: const ValueKey('paywall-price-line'),
                  textAlign: TextAlign.center,
                  style: LnText.meta.copyWith(fontSize: 12, height: 17 / 12)),
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _Link('Restore purchase', _restore),
                const SizedBox(width: 18),
                _Link('Terms',
                    () => openOrExplain(context, AppLinks.terms)),
                const SizedBox(width: 18),
                _Link('Privacy',
                    () => openOrExplain(context, AppLinks.privacyPolicy)),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature(this.icon, this.text, {this.last = false});
  final LnIcons icon;
  final String text;
  final bool last;
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : 10),
        child: Row(children: [
          LnIcon(icon, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: LnText.rowLabel)),
        ]),
      );
}

/// Today -> reminder -> first charge, with real dates.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.plan, required this.trial, required this.now});
  final Plan plan;
  final bool trial;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    if (trial) {
      final d = TrialDates.from(now, plan);
      rows.add(const _Step(
          icon: LnIcons.unlock,
          dark: true,
          title: 'Today',
          text: 'Full access. Nothing to pay.'));
      if (d.reminderAt != null) {
        rows.add(_Step(
            icon: LnIcons.bell,
            title: weekdayMonthDay(d.reminderAt!),
            text: 'We can remind you the trial is ending.'));
      }
      rows.add(_Step(
          icon: LnIcons.card,
          title: weekdayMonthDay(d.chargeAt),
          text:
              'You pay ${plan.priceLabel} ${forPeriodWords(plan)}, unless you cancel before.'));
    } else {
      rows.add(_Step(
          icon: LnIcons.card,
          dark: true,
          title: 'Today',
          text: 'You pay ${plan.priceLabel} ${forPeriodWords(plan)}.'));
      rows.add(_Step(
          icon: LnIcons.refresh,
          title: weekdayMonthDay(addPeriod(now, plan.period)),
          text: 'It renews, unless you cancel before.'));
    }
    return LnCard(
      child: Column(children: [
        for (var i = 0; i < rows.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == rows.length - 1 ? 0 : 12),
            child: rows[i],
          ),
      ]),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(
      {required this.icon,
      required this.title,
      required this.text,
      this.dark = false});
  final LnIcons icon;
  final String title;
  final String text;
  final bool dark;
  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: dark ? LnColors.ink : LnColors.fill,
                shape: BoxShape.circle),
            child: LnIcon(icon,
                size: 14, color: dark ? LnColors.card : LnColors.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: LnText.speakerName),
                  const SizedBox(height: 1),
                  Text(text, style: LnText.meta.copyWith(height: 18 / 13)),
                ]),
          ),
        ],
      );
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.name,
    required this.price,
    required this.sub,
    required this.selected,
    required this.onTap,
    this.tag,
  });
  final String name;
  final String price;
  final String sub;
  final String? tag;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        child: LnPressable(
          onPressed: onTap,
          pressedOpacity: 0.8,
          child: LnCard(
            selected: selected,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                        child: Text(name,
                            style: LnText.rowLabel.copyWith(
                                fontWeight: FontWeight.w600,
                                fontVariations: const [
                                  FontVariation('wght', 600)
                                ]))),
                    LnRadioMark(selected: selected),
                  ]),
                  const SizedBox(height: 4),
                  Text(price,
                      style: LnText.noteTitle.copyWith(fontSize: 24)),
                  const SizedBox(height: 4),
                  Row(children: [
                    Text(sub, style: LnText.meta.copyWith(fontSize: 12)),
                    if (tag != null) ...[
                      const SizedBox(width: 6),
                      LnGreenTag(tag!),
                    ],
                  ]),
                ]),
          ),
        ),
      );
}

class _Link extends StatelessWidget {
  const _Link(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(label,
              style: LnText.chip.copyWith(color: LnColors.ink3)),
        ),
      );
}
