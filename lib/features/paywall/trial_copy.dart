import '../../core/billing/billing_service.dart';
import '../../core/billing/trial_reminder.dart';
import '../common/dates.dart';

/// Dates of a trial started at [now] on [plan]: the reminder (26 h before
/// the end, same rule as the scheduled notification) and the first charge
/// (= trial end). [reminderAt] is null when the trial is too short for it.
class TrialDates {
  TrialDates._(this.start, this.chargeAt, this.reminderAt);

  factory TrialDates.from(DateTime now, Plan plan) {
    final end = now.add(Duration(days: plan.trialDays));
    return TrialDates._(now, end, trialReminderTime(end, now));
  }

  /// For a trial that is already running.
  factory TrialDates.running(DateTime start, DateTime end, DateTime now) =>
      TrialDates._(start, end, trialReminderTime(end, now));

  final DateTime start;
  final DateTime chargeAt;
  final DateTime? reminderAt;
}

/// "a year" / "a month"
String perPeriodWords(Plan p) => p.period == PlanPeriod.year ? 'a year' : 'a month';

/// "for the year" / "for the month"
String forPeriodWords(Plan p) =>
    p.period == PlanPeriod.year ? 'for the year' : 'for the month';

String planName(Plan p) => p.period == PlanPeriod.year ? 'Yearly' : 'Monthly';

Plan planForId(String? id) => id == monthlyPlan.id ? monthlyPlan : annualPlan;

/// Currency prefix of a store price label ("$" from "$59.99", "₹" from "₹4,999").
String _currency(Plan p) =>
    RegExp(r'^[^\d]*').firstMatch(p.priceLabel)?.group(0)?.trim() ?? '';

String _amount(double v) {
  final s = v.toStringAsFixed(2);
  return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
}

/// "$5 / mo" for the yearly card.
String monthlyEquivalent(Plan yearly) =>
    '${_currency(yearly)}${_amount(yearly.price / 12)} / mo';

/// Whole-percent saving of [yearly] over 12 x [monthly] ("Save 50%").
int yearlySavingPercent(Plan yearly, Plan monthly) =>
    ((1 - yearly.price / (monthly.price * 12)) * 100).round();

/// Line above the buy button: exact price and charge date.
String priceLine(Plan plan, {required bool trial, required DateTime now}) {
  final money = '${plan.priceLabel} ${perPeriodWords(plan)}';
  if (trial) {
    final d = TrialDates.from(now, plan);
    return 'Free until ${monthDay(d.chargeAt)}, then $money. '
        'Cancel any time in Settings → Apple ID.';
  }
  return '$money, charged today and renewed until you cancel. '
      'Cancel any time in Settings → Apple ID.';
}
