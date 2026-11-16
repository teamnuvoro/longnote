import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
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
/// Apple's subscriptions page. Billing is still simulated in this build.
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
    await s.billing.restore();
    if (!context.mounted) return;
    final e = s.billing.entitlement.value;
    showNote(
        context,
        e.isActive
            ? 'Your ${planName(planForId(e.planId)).toLowerCase()} plan is active.'
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
                  onPressed: () => context.pushNamed<bool>(R.paywall)),
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
            const SizedBox(height: 18),
            Text(
              'Test build: purchases are simulated. No money is charged.',
              textAlign: TextAlign.center,
              style: LnText.meta.copyWith(color: LnColors.ink3, fontSize: 12),
            ),
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
      text = 'Your trial ends ${weekdayMonthDay(end)} at ${clockTime(end)}. '
          'If you don’t cancel before then, Apple charges ${plan.priceLabel} '
          'and the plan renews ${_every(plan, end)}.';
    } else if (e.isActive) {
      over = '${planName(plan)} plan';
      big = '${plan.priceLabel} ${perPeriodWords(plan)}';
      text = e.renewsAt == null
          ? 'Renews until you cancel.'
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

class _Dates extends StatelessWidget {
  const _Dates({required this.e});
  final Entitlement e;

  @override
  Widget build(BuildContext context) {
    final plan = planForId(e.planId);
    final rows = <Widget>[];
    if (e.status == EntitlementStatus.trial && e.trialEndsAt != null) {
      final end = e.trialEndsAt!;
      // Same rule as the scheduled notification (26 h before the end).
      final remind = end.subtract(AppConfig.trialReminderLead);
      rows.add(LnListRow(
          icon: LnIcons.bell,
          label: 'Reminder',
          value: remind.isBefore(screenNow())
              ? 'Sent ${monthDay(remind)}'
              : weekdayMonthDay(remind)));
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
