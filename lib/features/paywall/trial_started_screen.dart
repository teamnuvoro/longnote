import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../ui/widgets.dart';
import '../common/dates.dart';
import '../common/external.dart';
import '../common/screen_clock.dart';
import '../common/widgets.dart';
import 'trial_copy.dart';

/// A2 Trial started (Figma 5:275). The only place that asks for the
/// notification permission, with its reason on screen: one reminder before
/// the first payment. "Allow the reminder" asks and schedules it; Skip is
/// fine. Either way the screen pops (the paywall then closes to Notes).
class TrialStartedScreen extends StatefulWidget {
  const TrialStartedScreen({super.key});
  @override
  State<TrialStartedScreen> createState() => _TrialStartedScreenState();
}

class _TrialStartedScreenState extends State<TrialStartedScreen> {
  bool _busy = false;

  Future<void> _allow() async {
    final s = context.read<AppServices>();
    final e = s.billing.entitlement.value;
    setState(() => _busy = true);
    var granted = false;
    try {
      await s.kv.setBool(AppServices.kvNotificationsAsked, true);
      granted = await s.reminderScheduler.requestPermission();
      if (granted && e.trialEndsAt != null) {
        await s.reminders.onTrialStarted(planForId(e.planId), e.trialEndsAt!);
      }
    } catch (_) {
      granted = false;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!granted) {
      showNote(context,
          'Notifications are off, so no reminder. You can turn them on in iPhone Settings → Longnote.');
    }
    _done();
  }

  void _done() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final e = s.billing.entitlement.value;
    final plan = planForId(e.planId);
    final end = e.trialEndsAt ?? screenNow().add(Duration(days: plan.trialDays));
    final dates = TrialDates.running(screenNow(), end, screenNow());
    final at = dates.reminderAt;
    final body = at == null
        ? 'Nothing is charged today. Your first payment of ${plan.priceLabel} is on ${longWeekdayMonthDay(end)}.'
        : 'Nothing is charged today. On ${longWeekdayMonthDay(at)} we’ll send one reminder, a day before your first payment of ${plan.priceLabel}.';
    return LnScaffold(
      backgroundColor: LnColors.paper,
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 116, 28, 0),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                          color: LnColors.savedTint, shape: BoxShape.circle),
                      child: const LnIcon(LnIcons.check,
                          size: 30, color: LnColors.saved),
                    ),
                    const SizedBox(height: 24),
                    Text('You’re in. Your trial is on.',
                        style: LnText.largeTitle
                            .copyWith(fontSize: 30, height: 36 / 30)),
                    const SizedBox(height: 10),
                    Text(body,
                        style: LnText.body.copyWith(color: LnColors.ink2)),
                    if (at != null) ...[
                      const SizedBox(height: 24),
                      LnCard(
                        child: Row(children: [
                          const LnIconTile(LnIcons.bell,
                              size: 40, iconSize: 20, radius: 12),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Trial reminder',
                                      style: LnText.rowTitleSmall),
                                  const SizedBox(height: 2),
                                  Text(
                                      '${weekdayMonthDay(at)} · ${clockTime(at)}',
                                      style: LnText.mono.copyWith(
                                          fontSize: 13, color: LnColors.ink2)),
                                ]),
                          ),
                        ]),
                      ),
                    ],
                  ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Column(children: [
              if (at != null) ...[
                LnPrimaryButton(
                    label: 'Allow the reminder', busy: _busy, onPressed: _allow),
                const SizedBox(height: 10),
                LnSecondaryButton(
                    label: 'Skip — I’ll remember', onPressed: _done),
              ] else
                LnPrimaryButton(label: 'Continue', onPressed: _done),
            ]),
          ),
        ]),
      ),
    );
  }
}
