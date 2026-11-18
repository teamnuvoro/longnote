import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../db/app_database.dart';
import 'billing_service.dart';

/// Real App Store subscriptions through StoreKit 2: the Swift `StorePlugin`
/// in ios/Runner/AppDelegate.swift, channel "longnote/store".
///
/// - Apple verifies every transaction on the device (signed for this app);
///   the native side drops unverified ones, so this class trusts what it
///   gets.
/// - The entitlement comes from `Transaction.currentEntitlements`, which
///   works offline from StoreKit's cache. A copy is kept in the KV store so
///   the app opens unlocked even if StoreKit answers slowly at launch.
/// - Prices and the trial come from the App Store (the user's currency).
class StoreKitBillingService implements BillingService {
  StoreKitBillingService({
    required this.kv,
    MethodChannel? channel,
    this.statusTimeout = const Duration(seconds: 5),
    this.productsTimeout = const Duration(seconds: 20),
  }) : _ch = channel ?? const MethodChannel('longnote/store');

  final KvStore kv;
  final MethodChannel _ch;
  final Duration statusTimeout;
  final Duration productsTimeout;

  static const cacheKey = 'store_entitlement';
  static const eligibleKey = 'store_trial_eligible';
  static const plansKey = 'store_plans';
  static const productIds = [
    'com.novaralabs.longnote.annual',
    'com.novaralabs.longnote.monthly',
  ];

  final ValueNotifier<Entitlement> _ent = ValueNotifier(const Entitlement());
  bool _eligible = true;
  final Map<String, Plan> _plans = {};
  Future<List<Plan>>? _loading;

  @override
  ValueListenable<Entitlement> get entitlement => _ent;

  /// From the App Store once products load; until then the last known
  /// answer (a fresh install is eligible). Apple's own sheet always shows
  /// the real terms before anything is charged.
  @override
  bool get trialEligible => _eligible;

  @override
  Future<void> init() async {
    final raw = await kv.get(cacheKey);
    if (raw != null) {
      try {
        _ent.value = Entitlement.fromJson(
            (jsonDecode(raw) as Map).cast<String, Object?>());
      } catch (_) {/* corrupt cache: StoreKit answers below */}
    }
    final elig = await kv.get(eligibleKey);
    if (elig != null) _eligible = elig == '1';
    if (_ent.value.isActive) _eligible = false;
    // Last known store prices, so screens never show USD to a ₹ subscriber
    // while the App Store is slow or offline.
    final plans = await kv.get(plansKey);
    if (plans != null) {
      try {
        for (final raw in jsonDecode(plans) as List) {
          final p = planFromStore((raw as Map).cast<String, Object?>());
          if (p != null) {
            _plans[p.id] = p;
            storePlans[p.id] = p;
          }
        }
      } catch (_) {/* corrupt cache: products load below */}
    }

    _ch.setMethodCallHandler((call) async {
      if (call.method == 'changed') await refresh();
    });
    try {
      await _readStatus().timeout(statusTimeout);
    } catch (e) {
      debugPrint('store status at launch: $e');
    }
    // Prices and trial eligibility in the background.
    unawaited(loadPlans());
  }

  /// Re-reads the entitlement from StoreKit (local, cheap). Called on
  /// resume, before a gate decision past the paid-through date, and on
  /// native "changed".
  @override
  Future<void> refresh() async {
    try {
      await _readStatus().timeout(statusTimeout);
    } catch (e) {
      debugPrint('store refresh: $e');
    }
  }

  Future<void> _readStatus() async {
    final m = await _ch.invokeMapMethod<String, Object?>('status');
    if (m != null) _apply(m);
  }

  void _apply(Map<String, Object?> m) {
    var e = entitlementFromStore(m, trialEligible: _eligible);
    final prev = _ent.value;
    // Keep the last known auto-renew answer until the network confirms it.
    if (prev.planId == e.planId && prev.renewsAt == e.renewsAt) {
      e = e.withRenewal(
          willRenew: prev.willRenew, switchesToPlanId: prev.switchesToPlanId);
    }
    _set(e);
    if (e.isActive && e.planId != null) unawaited(_fetchRenewal(e.planId!));
  }

  Future<void> _fetchRenewal(String productId) async {
    try {
      final r = await _ch.invokeMapMethod<String, Object?>(
          'renewal', {'productId': productId}).timeout(productsTimeout);
      final will = r?['willAutoRenew'];
      if (will is! bool) return;
      final pref = r?['autoRenewPreference'];
      final switches =
          pref is String && pref != productId && productIds.contains(pref)
              ? pref
              : null;
      final e = _ent.value;
      if (e.planId == productId &&
          (e.willRenew != will || e.switchesToPlanId != switches)) {
        _set(e.withRenewal(willRenew: will, switchesToPlanId: switches));
      }
    } catch (e) {
      debugPrint('store renewal info: $e');
    }
  }

  void _set(Entitlement e) {
    // A running plan used the trial; otherwise Apple's products answer
    // decides (a guess must be able to recover, e.g. another Apple ID).
    if (e.isActive) _eligible = false;
    _ent.value = e;
    _persist(cacheKey, jsonEncode(e.toJson()));
  }

  /// Cache writes never block the UI and never throw (the store is the
  /// source of truth; the cache only helps at the next launch).
  void _persist(String key, String value) {
    unawaited(() async {
      try {
        await kv.set(key, value);
      } catch (e) {
        debugPrint('store cache write: $e');
      }
    }());
  }

  void _setEligible(bool v) {
    _eligible = v;
    _persist(eligibleKey, v ? '1' : '0');
  }

  @override
  Future<List<Plan>> loadPlans() => _loading ??= _loadPlans().whenComplete(() {
        _loading = null;
      });

  Future<List<Plan>> _loadPlans() async {
    try {
      final list = await _ch.invokeListMethod<Object?>(
          'products', {'ids': productIds}).timeout(productsTimeout);
      final plans = <Plan>[];
      bool? eligible;
      for (final raw in list ?? const []) {
        if (raw is! Map) continue;
        final m = raw.cast<String, Object?>();
        final p = planFromStore(m);
        if (p == null) continue;
        plans.add(p);
        final e = m['eligibleForIntro'];
        if (e is bool) eligible = (eligible ?? true) && e;
      }
      if (eligible != null && !_ent.value.isActive) _setEligible(eligible);
      plans.sort((a, b) => a.period == b.period
          ? 0
          : a.period == PlanPeriod.year
              ? -1
              : 1);
      for (final p in plans) {
        _plans[p.id] = p;
        storePlans[p.id] = p;
      }
      if (plans.isNotEmpty) {
        _persist(
            plansKey,
            jsonEncode([
              for (final raw in list ?? const [])
                if (raw is Map && planFromStore(raw.cast<String, Object?>()) != null)
                  {
                    for (final k in const [
                      'id', 'displayPrice', 'price', 'periodUnit', 'trialDays',
                      'currency'
                    ])
                      k: raw[k]
                  }
            ]));
      }
      return plans;
    } catch (e) {
      debugPrint('store products: $e');
      return const [];
    }
  }

  @override
  Future<PurchaseResult> purchase(Plan plan) async {
    if (!_plans.containsKey(plan.id)) await loadPlans();
    if (!_plans.containsKey(plan.id)) {
      return const PurchaseResult(
          success: false,
          error: 'Can’t reach the App Store right now. Check your connection '
              'and try again. Nothing was charged.');
    }
    try {
      final r = await _ch
          .invokeMapMethod<String, Object?>('purchase', {'id': plan.id});
      switch (r?['result']) {
        case 'success':
          final st = r!['status'];
          if (st is Map) {
            _apply(st.cast<String, Object?>());
          } else {
            await refresh();
          }
          final e = _ent.value;
          if (!e.isActive) {
            return const PurchaseResult(
                success: false,
                error: 'The App Store took the purchase but it isn’t active '
                    'yet. Tap “Restore purchase” in a minute.');
          }
          _setEligible(false);
          // Apple's answer decides, not our earlier eligibility guess.
          return PurchaseResult(
              success: true, startedTrial: e.status == EntitlementStatus.trial);
        case 'cancelled':
          return const PurchaseResult(
              success: false, error: 'Purchase cancelled. Nothing was charged.');
        case 'pending':
          return const PurchaseResult(
              success: false,
              error: 'Waiting for approval. Longnote unlocks by itself once '
                  'the purchase is approved.');
        default:
          return const PurchaseResult(
              success: false,
              error: 'The App Store couldn’t complete the purchase. Nothing '
                  'was charged.');
      }
    } on PlatformException catch (e) {
      debugPrint('store purchase: ${e.code} ${e.message}');
      return const PurchaseResult(
          success: false,
          error: 'The App Store couldn’t complete the purchase. Please try '
              'again. Nothing was charged.');
    }
  }

  /// Asks the App Store for this Apple ID's purchases (may show Apple's
  /// sign-in sheet), then re-reads the entitlement.
  @override
  Future<RestoreResult> restore() async {
    try {
      final m = await _ch.invokeMapMethod<String, Object?>('restore');
      if (m != null) _apply(m);
      // Eligibility follows the restored history.
      unawaited(loadPlans());
      return _ent.value.isActive ? RestoreResult.restored : RestoreResult.none;
    } on PlatformException catch (e) {
      // Cancelled sign-in or no network: show what StoreKit has locally,
      // and say the App Store was not reached (not "no purchase").
      debugPrint('store restore: ${e.code} ${e.message}');
      await refresh();
      return _ent.value.isActive ? RestoreResult.restored : RestoreResult.failed;
    }
  }
}

/// Maps the native "products" entry to a [Plan]; null for anything that is
/// not one of our two subscriptions.
@visibleForTesting
Plan? planFromStore(Map<String, Object?> m) {
  final id = m['id'];
  final label = m['displayPrice'];
  final price = m['price'];
  if (id is! String || label is! String || price is! num) return null;
  if (!StoreKitBillingService.productIds.contains(id)) return null;
  final PlanPeriod period;
  switch (m['periodUnit']) {
    case 'month':
      period = PlanPeriod.month;
    case 'year':
      period = PlanPeriod.year;
    default:
      return null;
  }
  final trial = m['trialDays'];
  final currency = m['currency'];
  return Plan(
    id: id,
    period: period,
    price: price.toDouble(),
    priceLabel: label,
    trialDays: trial is int ? trial : 0,
    currency: currency is String && currency.isNotEmpty ? currency : 'USD',
  );
}

/// Maps the native "status" map to an [Entitlement].
@visibleForTesting
Entitlement entitlementFromStore(Map<String, Object?> m,
    {required bool trialEligible}) {
  if (m['active'] != true) {
    return Entitlement(trialUsed: !trialEligible);
  }
  final productId = m['productId'] as String?;
  final exp = m['expiresAtMs'];
  final expires = exp is int ? DateTime.fromMillisecondsSinceEpoch(exp) : null;
  if (m['isTrial'] == true && expires != null) {
    return Entitlement(
      status: EntitlementStatus.trial,
      planId: productId,
      trialEndsAt: expires,
      renewsAt: expires,
      trialUsed: true,
    );
  }
  return Entitlement(
    status: EntitlementStatus.active,
    planId: productId,
    renewsAt: expires,
    trialUsed: true,
  );
}
