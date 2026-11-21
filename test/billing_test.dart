import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/billing/paywall_gate.dart';
import 'package:longnote/core/billing/trial_reminder.dart';

import 'helpers/test_env.dart';

class _RecordingScheduler implements ReminderScheduler {
  final scheduled = <(int, DateTime, String)>[];
  final cancelled = <int>[];
  @override
  Future<void> schedule(
      {required int id,
      required DateTime at,
      required String title,
      required String body}) async {
    scheduled.add((id, at, body));
  }

  @override
  Future<void> cancel(int id) async => cancelled.add(id);
}

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  group('addPeriod clamps the day to the month length', () {
    test('month', () {
      expect(addPeriod(DateTime(2027, 1, 31, 9, 30), PlanPeriod.month),
          DateTime(2027, 2, 28, 9, 30));
      expect(addPeriod(DateTime(2028, 1, 31), PlanPeriod.month),
          DateTime(2028, 2, 29));
      expect(addPeriod(DateTime(2026, 3, 31), PlanPeriod.month),
          DateTime(2026, 4, 30));
      expect(addPeriod(DateTime(2026, 12, 31), PlanPeriod.month),
          DateTime(2027, 1, 31));
      expect(addPeriod(DateTime(2026, 11, 16), PlanPeriod.month),
          DateTime(2026, 12, 16));
      expect(addPeriod(DateTime.utc(2027, 1, 30), PlanPeriod.month),
          DateTime.utc(2027, 2, 28));
    });
    test('year', () {
      expect(addPeriod(DateTime(2028, 2, 29), PlanPeriod.year),
          DateTime(2029, 2, 28));
      expect(addPeriod(DateTime(2026, 11, 16), PlanPeriod.year),
          DateTime(2027, 11, 16));
    });
  });

  group('paywall gate: 30 free seconds, then the paywall', () {
    test('pure rule', () {
      const none = Entitlement();
      expect(PaywallGate.canStartRecording(freeSecondsUsed: 0, entitlement: none), isTrue);
      expect(PaywallGate.canStartRecording(freeSecondsUsed: 29, entitlement: none), isTrue);
      expect(PaywallGate.canStartRecording(freeSecondsUsed: 30, entitlement: none), isFalse);
      const trial = Entitlement(status: EntitlementStatus.trial);
      const active = Entitlement(status: EntitlementStatus.active);
      const expired = Entitlement(status: EntitlementStatus.expired);
      expect(PaywallGate.canStartRecording(freeSecondsUsed: 30, entitlement: trial), isTrue);
      expect(PaywallGate.canStartRecording(freeSecondsUsed: 30, entitlement: active), isTrue);
      expect(PaywallGate.canStartRecording(freeSecondsUsed: 30, entitlement: expired), isFalse);
    });

    test('free seconds add up across recordings, capped at 30', () async {
      final gate = PaywallGate(env.kv);
      const none = Entitlement();
      expect(await gate.freeLeft(), const Duration(seconds: 30));
      await gate.onRecordingFinished(const Duration(seconds: 12), wasEntitled: false);
      expect(await gate.freeLeft(), const Duration(seconds: 18));
      expect(await gate.canStart(none), isTrue);
      await gate.onRecordingFinished(const Duration(hours: 3), wasEntitled: false);
      expect(await gate.freeSecondsUsed(), 30);
      expect(await gate.freeLeft(), Duration.zero);
      expect(await gate.canStart(none), isFalse);
    });

    test('a 1.0 user who used the free recording has no free seconds', () async {
      await env.kv.setInt(PaywallGate.legacyFreeUsedKey, 1);
      final gate = PaywallGate(env.kv);
      expect(await gate.freeLeft(), Duration.zero);
      expect(await gate.canStart(const Entitlement()), isFalse);
    });

    test('recordings made while subscribed do not count', () async {
      final gate = PaywallGate(env.kv);
      await gate.onRecordingFinished(const Duration(hours: 1), wasEntitled: true);
      expect(await gate.freeSecondsUsed(), 0);
    });
  });

  group('trial reminder date math', () {
    test('reminder is 26 h before the trial ends (before any Apple charge)', () {
      final now = DateTime(2026, 11, 15, 22, 30);
      final ends = now.add(const Duration(days: 3));
      final at = trialReminderTime(ends, now)!;
      expect(at, DateTime(2026, 11, 17, 20, 30));
      expect(ends.difference(at), const Duration(hours: 26));
      // At least 24 h before the charge so the user can still cancel.
      expect(ends.difference(at) >= const Duration(hours: 24), isTrue);
    });

    test('works across month/year boundaries', () {
      final now = DateTime(2026, 12, 30, 9);
      final at = trialReminderTime(now.add(const Duration(days: 3)), now)!;
      expect(at, DateTime(2027, 1, 1, 7));
    });

    test('never schedules in the past', () {
      final now = DateTime(2026, 11, 15);
      expect(trialReminderTime(now.add(const Duration(hours: 20)), now), isNull);
      expect(trialReminderTime(now.subtract(const Duration(days: 1)), now), isNull);
    });

    test('service schedules with full price and date in the text', () async {
      final sched = _RecordingScheduler();
      final svc = TrialReminderService(sched, clock: env.clock);
      final ends = env.clock.now().add(const Duration(days: 3));
      final at = await svc.onTrialStarted(annualPlan, ends);
      expect(at, ends.subtract(const Duration(hours: 26)));
      expect(sched.cancelled, [TrialReminderService.notificationId]);
      final (id, scheduledAt, body) = sched.scheduled.single;
      expect(id, TrialReminderService.notificationId);
      expect(scheduledAt, at);
      expect(body, contains(r'$59.99'));
      expect(body, contains(formatDate(ends)));
      expect(body, contains('cancel'));
    });
  });

  group('fake billing', () {
    test('only monthly and annual plans, no weekly', () async {
      final b = FakeBillingService(kv: env.kv, clock: env.clock);
      final plans = await b.loadPlans();
      expect(plans.map((p) => p.period).toSet(), {PlanPeriod.month, PlanPeriod.year});
      expect(plans.map((p) => p.priceLabel).toSet(), {r'$9.99', r'$59.99'});
      expect(plans.every((p) => p.trialDays == 3), isTrue);
    });

    test('purchase starts a 3-day trial once; renews into active', () async {
      final b = FakeBillingService(kv: env.kv, clock: env.clock);
      await b.init();
      expect(b.trialEligible, isTrue);
      final r = await b.purchase(monthlyPlan);
      expect(r.startedTrial, isTrue);
      final e = b.entitlement.value;
      expect(e.status, EntitlementStatus.trial);
      expect(e.trialEndsAt, env.clock.now().add(const Duration(days: 3)));
      expect(e.renewsAt, e.trialEndsAt);
      expect(b.trialEligible, isFalse);

      // Persisted across launches; after the trial it becomes active.
      env.clock.advance(const Duration(days: 3, minutes: 1));
      final b2 = FakeBillingService(kv: env.kv, clock: env.clock);
      await b2.init();
      expect(b2.entitlement.value.status, EntitlementStatus.active);
      expect(b2.entitlement.value.renewsAt, DateTime(2026, 12, 18, 10, 0));
    });
  });

  test('a cancelled / refunded / ended trial removes its reminder', () async {
    final sched = _RecordingScheduler();
    final r = TrialReminderService(sched, kv: env.kv, clock: env.clock);
    final end = env.clock.now().add(const Duration(days: 3));
    await r.onTrialStarted(annualPlan, end);
    final trial = Entitlement(
        status: EntitlementStatus.trial,
        planId: annualPlan.id,
        trialEndsAt: end,
        renewsAt: end,
        trialUsed: true);
    await r.syncWith(trial);
    expect(sched.cancelled.length, 1, reason: 'only the reset in onTrialStarted');
    // Cancelled in iPhone Settings: no charge is coming, no reminder.
    await r.syncWith(trial.withRenewal(willRenew: false));
    expect(sched.cancelled.length, 2);
    expect(await r.scheduledFor(end), isNull);
    // Nothing scheduled any more: no further cancels.
    await r.syncWith(const Entitlement());
    expect(sched.cancelled.length, 2);
  });
}
