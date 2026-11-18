import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../app/nav.dart';
import '../../app_services.dart';
import '../../core/billing/billing_service.dart';
import '../../core/config.dart';
import '../../ui/widgets.dart';
import '../common/dates.dart';
import '../common/external.dart';
import '../common/links.dart';
import '../common/screen_clock.dart';
import '../common/widgets.dart';
import '../paywall/trial_copy.dart';

/// G4 Plan & billing (Figma 10:961): the plan, real dates from the billing
/// state (reminder, first charge, renewal), how to cancel, and a button to
/// Apple's subscriptions page.
class PlanScreen extends StatelessWidget {
  const PlanScreen({super.key});

  Future<void> _manage(BuildContext context) async {
    final ok = await External.openUrl(Uri.parse(AppLinks.manageSubscriptions));
    if (ok || !context.mounted) return;
    await openOrExplain(context, AppLinks.manageSubscriptionsWeb,
        failText:
            'Open iPhone Settings → your name → Subscriptions to cancel or change.');
  }

  Future<void> _restore(BuildContext context) async {
    final s = context.read<AppServices>();
    final r = await s.restorePurchases('plan');
    if (!context.mounted) return;
    final e = s.billing.entitlement.value;
    showNote(
        context,
        e.isActive
            ? 'Your ${planName(planForId(e.planId)).toLowerCase()} plan is active.'
            : r == RestoreResult.failed
                ? 'Couldn’t reach the App Store. Check your connection and try again.'
                : 'No purchase found to restore on this Apple ID.');
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return LnScaffold(
      backgroundColor: LnColors.paper,
      appBar: const LnNavBar(title: 'Plan & billing', backLabel: 'Settings'),
      body: ValueListenableBuilder<Entitlement>(
        valueListenable: s.billing.entitlement,
        builder: (context, e, _) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 40),
          children: [
            _Summary(e: e),
            if (e.isActive) ...[
              const SizedBox(height: 18),
              const LnSectionLabel('Dates'),
              _Dates(e: e),
              const SizedBox(height: 18),
              const LnSectionLabel('How to cancel'),
              _HowToCancel(e: e),
              const SizedBox(height: 16),
              LnSecondaryButton(
                  label: 'Cancel or change plan',
                  onPressed: () => _manage(context)),
            ] else ...[
              const SizedBox(height: 16),
              LnPrimaryButton(
                  label: 'See plans',
                  onPressed: () => context.pushOnce<bool>(R.paywall)),
            ],
            const SizedBox(height: 10),
            Center(
              child: LnPressable(
                onPressed: () => _restore(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                  child: Text('Restore purchase',
                      style: LnText.speakerName.copyWith(color: LnColors.ink2)),
                ),
              ),
            ),
            if (s.billing is FakeBillingService) ...[
              const SizedBox(height: 18),
              Text(
                'Test build: purchases are simulated. No money is charged.',
                textAlign: TextAlign.center,
                style: LnText.meta.copyWith(color: LnColors.ink3, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.e});
  final Entitlement e;

  @override
  Widget build(BuildContext context) {
    final plan = planForId(e.planId);
    final String over;
    final String big;
    final String text;
    if (e.status == EntitlementStatus.trial && e.trialEndsAt != null) {
      final end = e.trialEndsAt!;
      over = '${planName(plan)} plan · free trial';
      big = '${plan.priceLabel} ${perPeriodWords(plan)}';
      text = e.willRenew
          ? 'Your trial ends ${weekdayMonthDay(end)} at ${clockTime(end)}. '
              'If you don’t cancel before then, Apple charges ${plan.priceLabel} '
              'and the plan renews ${_every(plan, end)}.'
          : 'You cancelled. The trial stays on until ${weekdayMonthDay(end)} '
              'at ${clockTime(end)}, and you won’t be charged.';
    } else if (e.isActive) {
      over = '${planName(plan)} plan';
      big = '${plan.priceLabel} ${perPeriodWords(plan)}';
      text = e.renewsAt == null
          ? 'Renews until you cancel.'
          : !e.willRenew
              ? 'You cancelled. Your plan stays on until '
                  '${monthDayYear(e.renewsAt!)}. No more charges.'
          : e.switchesToPlanId != null
              ? 'On ${monthDayYear(e.renewsAt!)} it switches to '
                  '${planName(planForId(e.switchesToPlanId)).toLowerCase()}: '
                  '${planForId(e.switchesToPlanId).priceLabel} '
                  '${perPeriodWords(planForId(e.switchesToPlanId))} until you cancel.'
          : 'Next charge ${monthDayYear(e.renewsAt!)}: ${plan.priceLabel}. '
              'It renews ${_every(plan, e.renewsAt!)} until you cancel.';
    } else {
      over = 'No plan';
      big = 'Free';
      text = 'Your first recording is free, any length. Your notes stay yours '
          'with or without a plan.';
    }
    return LnCard(
      radius: 18,
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(over, style: LnText.caption),
        const SizedBox(height: 6),
        Text(big, style: LnText.detailTitle.copyWith(fontSize: 30, height: null)),
        const SizedBox(height: 6),
        Text(text, style: LnText.preview.copyWith(height: 21 / 14)),
      ]),
    );
  }
}

/// "every year on Nov 19" / "every month on the 19th"
String _every(Plan p, DateTime d) => p.period == PlanPeriod.year
    ? 'every year on ${monthDay(d)}'
    : 'every month on the ${ordinal(d.day)}';

class _Dates extends StatefulWidget {
  const _Dates({required this.e});
  final Entitlement e;

  @override
  State<_Dates> createState() => _DatesState();
}

class _DatesState extends State<_Dates> {
  /// The reminder actually scheduled for this trial (null = none: the user
  /// skipped or denied notifications on A2).
  DateTime? _scheduled;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_Dates old) {
    super.didUpdateWidget(old);
    if (old.e.trialEndsAt != widget.e.trialEndsAt) _load();
  }

  Future<void> _load() async {
    final end = widget.e.trialEndsAt;
    final at = end == null
        ? null
        : await context.read<AppServices>().reminders.scheduledFor(end);
    if (!mounted) return;
    setState(() {
      _scheduled = at;
      _loaded = true;
    });
  }

  Future<void> _turnOn() async {
    final s = context.read<AppServices>();
    final e = widget.e;
    if (_busy || e.trialEndsAt == null) return;
    setState(() => _busy = true);
    var granted = false;
    DateTime? at;
    try {
      await s.kv.setBool(AppServices.kvNotificationsAsked, true);
      granted = await s.reminderScheduler.requestPermission();
      if (granted) {
        at = await s.reminders.onTrialStarted(planForId(e.planId), e.trialEndsAt!);
      }
    } catch (_) {
      granted = false;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _scheduled = at;
    });
    if (!granted) {
      showNote(context,
          'Notifications are off. Turn them on in iPhone Settings → Longnote, then try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.e;
    final plan = planForId(e.planId);
    final rows = <Widget>[];
    if (e.status == EntitlementStatus.trial && e.trialEndsAt != null) {
      final end = e.trialEndsAt!;
      // Same rule as the scheduled notification (26 h before the end).
      final remind = end.subtract(AppConfig.trialReminderLead);
      final canRemind = remind.isAfter(screenNow());
      if (!_loaded) {
        rows.add(const LnListRow(icon: LnIcons.bell, label: 'Reminder'));
      } else if (_scheduled != null) {
        rows.add(LnListRow(
            icon: LnIcons.bell,
            label: 'Reminder',
            value: remind.isBefore(screenNow())
                ? 'Sent ${monthDay(remind)}'
                : weekdayMonthDay(remind)));
      } else {
        rows.add(LnListRow(
            icon: LnIcons.bell,
            label: 'Reminder',
            value: 'Off',
            subtitle: canRemind ? 'Tap to get one reminder before the first charge' : null,
            onTap: canRemind ? _turnOn : null));
      }
      rows.add(LnListRow(
          icon: LnIcons.card, label: 'First charge', value: weekdayMonthDay(end)));
      rows.add(LnListRow(
          icon: LnIcons.refresh,
          label: 'Renews',
          value: plan.period == PlanPeriod.year
              ? 'Every ${monthDay(end)}'
              : 'Monthly, the ${ordinal(end.day)}'));
    } else if (e.renewsAt != null) {
      final next = e.renewsAt!;
      rows.add(LnListRow(
          icon: LnIcons.card, label: 'Next charge', value: weekdayMonthDay(next)));
      rows.add(LnListRow(
          icon: LnIcons.refresh,
          label: 'Renews',
          value: plan.period == PlanPeriod.year
              ? 'Every ${monthDay(next)}'
              : 'Monthly, the ${ordinal(next.day)}'));
    }
    return LnCardGroup.settings(children: rows);
  }
}

class _HowToCancel extends StatelessWidget {
  const _HowToCancel({required this.e});
  final Entitlement e;

  @override
  Widget build(BuildContext context) {
    final until = e.status == EntitlementStatus.trial
        ? e.trialEndsAt
        : e.renewsAt;
    final steps = [
      'Tap “Cancel or change plan” below.',
      'Apple opens your subscriptions.',
      until == null
          ? 'Choose Longnote → Cancel.'
          : 'Choose Longnote → Cancel. You keep access until ${monthDay(until)}.',
    ];
    return LnCard(
      child: Column(children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                    color: LnColors.fill, shape: BoxShape.circle),
                child: Text('${i + 1}',
                    style: LnText.smallButton.copyWith(fontSize: 12)),
              ),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(steps[i],
                      style: LnText.preview
                          .copyWith(color: LnColors.ink))),
            ]),
          ),
      ]),
    );
  }
}
