import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/analytics/analytics.dart';
import '../../core/billing/billing_service.dart';
import '../../core/billing/trial_reminder.dart';
import '../../core/config.dart';

/// Honest paywall. Shown when starting the 2nd recording.
/// - Monthly and annual only (no weekly plan).
/// - Shows the full price, the date of the first charge, and that it renews.
/// - "How to cancel" is on screen BEFORE the buy button.
/// - A reminder is scheduled ~1 day before the trial ends.
/// Pops with `true` when the user now has access.
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
  List<Plan> _plans = const [];
  Plan? _selected;
  bool _busy = false;

  AppServices get _s => context.read<AppServices>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _s.analytics.log(AnalyticsEvent.paywallViewed,
          props: {'placement': widget.placement});
      final plans = await _s.billing.loadPlans();
      if (!mounted) return;
      setState(() {
        _plans = plans;
        _selected = plans.firstWhere((p) => p.period == PlanPeriod.year,
            orElse: () => plans.first);
      });
    });
  }

  Future<void> _buy() async {
    final plan = _selected;
    if (plan == null) return;
    setState(() => _busy = true);
    final trial = _s.billing.trialEligible;
    final res = await _s.billing.purchase(plan);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!res.success) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.error ?? 'Purchase did not complete.')));
      return;
    }
    if (res.startedTrial && trial) {
      final ends = _s.billing.entitlement.value.trialEndsAt!;
      await _s.analytics.log(AnalyticsEvent.trialStarted,
          props: {'plan': plan.id, 'trial_ends_at': ends.toIso8601String()});
      // Permission prompt comes with a clear reason: the reminder itself.
      try {
        await _s.reminderScheduler.requestPermission();
        await _s.reminders.onTrialStarted(plan, ends);
      } catch (_) {
        // Notifications unavailable: the paywall already showed the date.
      }
    }
    if (mounted) _close(true);
  }

  void _close(bool subscribed) {
    final done = widget.onDone;
    if (done != null) {
      done(context, subscribed);
    } else {
      Navigator.of(context).pop(subscribed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final plan = _selected;
    final trial = _s.billing.trialEligible;
    final now = DateTime.now();
    final firstCharge = plan == null
        ? null
        : (trial ? now.add(Duration(days: plan.trialDays)) : now);
    final cancelBy = firstCharge?.subtract(const Duration(hours: 24));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Not now',
          icon: const Icon(Icons.close),
          onPressed: () => _close(false),
        ),
        title: const Text('Keep recording'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              color: cs.tertiaryContainer,
              child: Text('Test build: purchases here are simulated. No money is charged.',
                  style: t.bodySmall?.copyWith(color: cs.onTertiaryContainer)),
            ),
            const SizedBox(height: 16),
            Text('You have used your free recording', style: t.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Subscribe to record as much as you want, as long as you want. '
              'Your free recording and its notes stay yours either way.',
              style: t.bodyLarge,
            ),
            const SizedBox(height: 16),
            for (final f in const [
              'Unlimited recordings, hours long',
              'Transcripts made on your phone',
              'Summaries with decisions and action items',
              'PDF, text and audio export',
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Icon(Icons.check, color: cs.primary, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text(f)),
                ]),
              ),
            const SizedBox(height: 16),
            for (final p in _plans)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                      color: p == plan ? cs.primary : cs.outlineVariant,
                      width: p == plan ? 2 : 1),
                ),
                child: RadioListTile<Plan>(
                  value: p,
                  // ignore: deprecated_member_use
                  groupValue: plan,
                  // ignore: deprecated_member_use
                  onChanged: (v) => setState(() => _selected = v),
                  title: Text(p.period == PlanPeriod.year ? 'Yearly' : 'Monthly',
                      style: t.titleMedium),
                  subtitle: Text(p.period == PlanPeriod.year
                      ? '${p.priceLabel} per year (about \$${(p.price / 12).toStringAsFixed(2)} a month)'
                      : '${p.priceLabel} per month'),
                ),
              ),
            const SizedBox(height: 12),
            if (plan != null && firstCharge != null)
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('What you will pay', style: t.titleSmall),
                    const SizedBox(height: 6),
                    Text(trial
                        ? 'Today: \$0. Free for ${plan.trialDays} days.\n'
                            'On ${formatDate(firstCharge)}: ${plan.priceLabel}, then ${plan.priceLabel} every ${plan.periodWord} until you cancel.'
                        : 'Today: ${plan.priceLabel}, then ${plan.priceLabel} every ${plan.periodWord} until you cancel.'),
                    if (trial) ...[
                      const SizedBox(height: 6),
                      Text('We will send you a reminder about a day before the trial ends.',
                          style: t.bodySmall),
                    ],
                    const SizedBox(height: 12),
                    Text('How to cancel', style: t.titleSmall),
                    const SizedBox(height: 6),
                    Text(
                      'iPhone Settings > your name > Subscriptions > Longnote > Cancel Subscription. '
                      '${trial ? 'Cancel before ${formatDate(cancelBy!)} and you pay nothing. ' : ''}'
                      'Cancelling stops the next renewal; you keep access until the end of the period you paid for.',
                    ),
                  ]),
                ),
              ),
            const SizedBox(height: 20),
            SizedBox(
              height: 54,
              child: FilledButton(
                onPressed: _busy || plan == null ? null : _buy,
                child: _busy
                    ? const SizedBox(
                        width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(trial ? 'Start ${AppConfig.trialDays}-day free trial' : 'Subscribe'),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                await _s.billing.restore();
                if (!context.mounted) return;
                if (_s.billing.entitlement.value.isActive) {
                  _close(true);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('No active subscription found.')));
                }
              },
              child: const Text('Restore purchases'),
            ),
            Text(
              'Payment is charged to your Apple ID. The subscription renews automatically unless cancelled at least 24 hours before the end of the current period.',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
