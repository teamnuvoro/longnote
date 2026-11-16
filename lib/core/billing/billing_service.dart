import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../db/app_database.dart';
import '../util/clock.dart';

enum PlanPeriod { month, year }

/// A subscription product. Only monthly and annual exist: no weekly plan.
class Plan {
  const Plan({
    required this.id,
    required this.period,
    required this.price,
    required this.priceLabel,
    this.trialDays = AppConfig.trialDays,
  });

  /// App Store product id (to be created in App Store Connect).
  final String id;
  final PlanPeriod period;
  final double price;

  /// Localized price string from the store (e.g. "$9.99").
  final String priceLabel;
  final int trialDays;

  String get periodWord => period == PlanPeriod.month ? 'month' : 'year';

  /// "$59.99 / year" style, and the monthly equivalent for annual.
  String get perPeriod => '$priceLabel / $periodWord';
}

const monthlyPlan = Plan(
    id: 'com.novaralabs.longnote.monthly',
    period: PlanPeriod.month,
    price: 9.99,
    priceLabel: r'$9.99');
const annualPlan = Plan(
    id: 'com.novaralabs.longnote.annual',
    period: PlanPeriod.year,
    price: 59.99,
    priceLabel: r'$59.99');

enum EntitlementStatus { none, trial, active, expired }

@immutable
class Entitlement {
  const Entitlement({
    this.status = EntitlementStatus.none,
    this.planId,
    this.trialEndsAt,
    this.renewsAt,
    this.trialUsed = false,
  });

  final EntitlementStatus status;
  final String? planId;
  final DateTime? trialEndsAt;

  /// Next charge date (the trial end during a trial).
  final DateTime? renewsAt;

  /// Apple allows one introductory trial per subscription group.
  final bool trialUsed;

  bool get isActive =>
      status == EntitlementStatus.trial || status == EntitlementStatus.active;

  Map<String, Object?> toJson() => {
        'status': status.name,
        'planId': planId,
        'trialEndsAt': trialEndsAt?.toIso8601String(),
        'renewsAt': renewsAt?.toIso8601String(),
        'trialUsed': trialUsed,
      };

  factory Entitlement.fromJson(Map<String, Object?> j) => Entitlement(
        status: EntitlementStatus.values.firstWhere(
            (e) => e.name == j['status'],
            orElse: () => EntitlementStatus.none),
        planId: j['planId'] as String?,
        trialEndsAt: j['trialEndsAt'] == null
            ? null
            : DateTime.parse(j['trialEndsAt'] as String),
        renewsAt: j['renewsAt'] == null
            ? null
            : DateTime.parse(j['renewsAt'] as String),
        trialUsed: (j['trialUsed'] as bool?) ?? false,
      );
}

class PurchaseResult {
  const PurchaseResult({required this.success, this.startedTrial = false, this.error});
  final bool success;
  final bool startedTrial;
  final String? error;
}

/// Billing behind an interface. v1 ships [FakeBillingService]; a StoreKit
/// implementation (`in_app_purchase` or RevenueCat) replaces it without UI
/// changes. See docs/DECISIONS.md.
abstract class BillingService {
  ValueListenable<Entitlement> get entitlement;
  Future<void> init();
  Future<List<Plan>> loadPlans();
  Future<PurchaseResult> purchase(Plan plan);
  Future<void> restore();

  /// Whether this user can still get the free trial.
  bool get trialEligible;
}

/// Dev/fake billing: no money, no StoreKit. Simulates Apple's rules closely
/// enough to build and test the honest paywall and the trial reminder.
class FakeBillingService implements BillingService {
  FakeBillingService({required this.kv, Clock clock = const SystemClock()})
      : _clock = clock;

  final KvStore kv;
  final Clock _clock;
  final ValueNotifier<Entitlement> _ent = ValueNotifier(const Entitlement());
  static const _key = 'fake_billing_entitlement';

  @override
  ValueListenable<Entitlement> get entitlement => _ent;

  @override
  bool get trialEligible => !_ent.value.trialUsed;

  @override
  Future<void> init() async {
    final raw = await kv.get(_key);
    if (raw != null) {
      _ent.value = Entitlement.fromJson(
          (jsonDecode(raw) as Map).cast<String, Object?>());
    }
    _roll();
  }

  /// Moves a trial past its end date to "active" (simulated renewal).
  void _roll() {
    final e = _ent.value;
    final now = _clock.now();
    if (e.status == EntitlementStatus.trial &&
        e.trialEndsAt != null &&
        now.isAfter(e.trialEndsAt!)) {
      final plan = e.planId == monthlyPlan.id ? monthlyPlan : annualPlan;
      _set(Entitlement(
        status: EntitlementStatus.active,
        planId: e.planId,
        trialUsed: true,
        renewsAt: addPeriod(e.trialEndsAt!, plan.period),
      ));
    }
  }

  void _set(Entitlement e) {
    _ent.value = e;
    kv.set(_key, jsonEncode(e.toJson()));
  }

  @override
  Future<List<Plan>> loadPlans() async => const [annualPlan, monthlyPlan];

  @override
  Future<PurchaseResult> purchase(Plan plan) async {
    final now = _clock.now();
    if (trialEligible && plan.trialDays > 0) {
      final end = now.add(Duration(days: plan.trialDays));
      _set(Entitlement(
        status: EntitlementStatus.trial,
        planId: plan.id,
        trialEndsAt: end,
        renewsAt: end,
        trialUsed: true,
      ));
      return const PurchaseResult(success: true, startedTrial: true);
    }
    _set(Entitlement(
      status: EntitlementStatus.active,
      planId: plan.id,
      trialUsed: true,
      renewsAt: addPeriod(now, plan.period),
    ));
    return const PurchaseResult(success: true);
  }

  @override
  Future<void> restore() async => _roll();

  /// Dev only: reset to a fresh install's billing state.
  Future<void> resetForDev() async => _set(const Entitlement());
}

/// One billing period later, the way the App Store renews: the day is
/// clamped to the target month's length (Jan 31 + 1 month = Feb 28/29,
/// Feb 29 + 1 year = Feb 28), never rolled into the next month.
DateTime addPeriod(DateTime from, PlanPeriod p) {
  var y = from.year, m = from.month;
  if (p == PlanPeriod.month) {
    m += 1;
    if (m > 12) {
      m = 1;
      y += 1;
    }
  } else {
    y += 1;
  }
  final lastDay = DateTime.utc(y, m + 1, 0).day;
  final d = from.day > lastDay ? lastDay : from.day;
  return from.isUtc
      ? DateTime.utc(y, m, d, from.hour, from.minute)
      : DateTime(y, m, d, from.hour, from.minute);
}
