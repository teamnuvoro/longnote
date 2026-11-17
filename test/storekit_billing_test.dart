import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/billing/storekit_billing_service.dart';
import 'package:longnote/features/paywall/trial_copy.dart';

import 'helpers/test_env.dart';

const _ch = MethodChannel('longnote/store');

/// A pretend App Store behind the "longnote/store" channel.
class _FakeStore {
  Map<String, Object?> status = {'active': false};
  bool eligible = true;
  bool productsFail = false;
  String purchaseResult = 'success';
  bool? willRenew = true;
  String? renewInto;
  bool? grantTrial;
  bool restoreThrows = false;
  final calls = <String>[];

  static Map<String, Object?> product(String id, String unit, String label,
          double price) =>
      {
        'id': id,
        'displayPrice': label,
        'price': price,
        'currency': 'INR',
        'periodUnit': unit,
        'periodValue': 1,
        'trialDays': 3,
      };

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'status':
        return status;
      case 'products':
        if (productsFail) {
          throw PlatformException(code: 'store_error', message: 'offline');
        }
        return [
          {
            ...product('com.novaralabs.longnote.monthly', 'month', '₹999', 999),
            'eligibleForIntro': eligible
          },
          {
            ...product('com.novaralabs.longnote.annual', 'year', '₹5,900', 5900),
            'eligibleForIntro': eligible
          },
          // Not ours: ignored.
          {...product('other.thing', 'month', r'$1', 1), 'eligibleForIntro': true},
        ];
      case 'purchase':
        if (purchaseResult == 'success') {
          final id = (call.arguments as Map)['id'] as String;
          status = {
            'active': true,
            'productId': id,
            'isTrial': grantTrial ?? eligible,
            'expiresAtMs': DateTime(2026, 11, 21, 10).millisecondsSinceEpoch,
          };
          eligible = false;
          return {'result': 'success', 'status': status};
        }
        return {'result': purchaseResult};
      case 'restore':
        if (restoreThrows) {
          throw PlatformException(code: 'store_error', message: 'cancelled');
        }
        return status;
      case 'renewal':
        if (willRenew == null) return null;
        return {
          'willAutoRenew': willRenew,
          if (renewInto != null) 'autoRenewPreference': renewInto,
        };
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestEnv env;
  late _FakeStore store;

  setUp(() async {
    env = await TestEnv.create();
    store = _FakeStore();
    storePlans.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ch, store.handle);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ch, null);
    storePlans.clear();
    await env.dispose();
  });

  Future<StoreKitBillingService> boot() async {
    final b = StoreKitBillingService(kv: env.kv);
    await b.init();
    await b.loadPlans();
    return b;
  }

  test('loads our two plans with the store price, yearly first', () async {
    final b = await boot();
    final plans = await b.loadPlans();
    expect(plans.map((p) => p.id), [
      'com.novaralabs.longnote.annual',
      'com.novaralabs.longnote.monthly',
    ]);
    expect(plans.first.priceLabel, '₹5,900');
    expect(plans.first.trialDays, 3);
    expect(b.trialEligible, isTrue);
    // Screens show the user's currency.
    expect(planForId('com.novaralabs.longnote.monthly').priceLabel, '₹999');
    expect(b.entitlement.value.isActive, isFalse);
  });

  test('buying with a trial: trial entitlement, trial no longer offered',
      () async {
    final b = await boot();
    final plan = (await b.loadPlans()).first;
    final r = await b.purchase(plan);
    expect(r.success, isTrue);
    expect(r.startedTrial, isTrue);
    final e = b.entitlement.value;
    expect(e.status, EntitlementStatus.trial);
    expect(e.planId, plan.id);
    expect(e.trialEndsAt, DateTime(2026, 11, 21, 10));
    expect(b.trialEligible, isFalse);
  });

  test('not eligible: purchase is a paid subscription, not a trial', () async {
    store.eligible = false;
    final b = await boot();
    expect(b.trialEligible, isFalse);
    final r = await b.purchase((await b.loadPlans()).last);
    expect(r.success, isTrue);
    expect(r.startedTrial, isFalse);
    expect(b.entitlement.value.status, EntitlementStatus.active);
  });

  test('cancelled / pending purchase: nothing unlocked, honest message',
      () async {
    final b = await boot();
    final plan = (await b.loadPlans()).first;
    store.purchaseResult = 'cancelled';
    var r = await b.purchase(plan);
    expect(r.success, isFalse);
    expect(r.error, contains('Nothing was charged'));
    store.purchaseResult = 'pending';
    r = await b.purchase(plan);
    expect(r.success, isFalse);
    expect(r.error, contains('approv'));
    expect(b.entitlement.value.isActive, isFalse);
  });

  test('store unreachable: purchase fails without calling purchase', () async {
    store.productsFail = true;
    final b = await boot();
    final r = await b.purchase(annualPlan);
    expect(r.success, isFalse);
    expect(r.error, contains('App Store'));
    expect(store.calls, isNot(contains('purchase')));
  });

  test('restore finds an active plan; a failed restore keeps local state',
      () async {
    final b = await boot();
    store.status = {
      'active': true,
      'productId': 'com.novaralabs.longnote.monthly',
      'isTrial': false,
      'expiresAtMs': DateTime(2026, 12, 17).millisecondsSinceEpoch,
    };
    await b.restore();
    expect(b.entitlement.value.status, EntitlementStatus.active);
    expect(b.entitlement.value.renewsAt, DateTime(2026, 12, 17));
    store.restoreThrows = true;
    await b.restore();
    expect(b.entitlement.value.isActive, isTrue);
  });

  test('restore that cannot reach the App Store says failed, not "none"',
      () async {
    final b = await boot();
    store.restoreThrows = true;
    expect(await b.restore(), RestoreResult.failed);
    store.restoreThrows = false;
    expect(await b.restore(), RestoreResult.none);
  });

  test('refund / revocation: "changed" to inactive locks the app', () async {
    store.status = {
      'active': true,
      'productId': 'com.novaralabs.longnote.monthly',
      'isTrial': false,
      'expiresAtMs': DateTime(2026, 12, 17).millisecondsSinceEpoch,
    };
    final b = await boot();
    expect(b.entitlement.value.isActive, isTrue);
    store.status = {'active': false};
    await b.refresh();
    expect(b.entitlement.value.isActive, isFalse);
    expect(b.trialEligible, isFalse);
  });

  test('Apple grants a trial although we guessed "not eligible": the trial '
      'flow (A2 + reminder) still runs', () async {
    store.eligible = false; // products say: no trial
    final b = await boot();
    expect(b.trialEligible, isFalse);
    store.grantTrial = true; // ...but Apple's purchase starts one
    final r = await b.purchase((await b.loadPlans()).first);
    expect(r.startedTrial, isTrue);
    expect(b.entitlement.value.status, EntitlementStatus.trial);
  });

  test('plan change: auto-renew preference to another plan is shown',
      () async {
    store.status = {
      'active': true,
      'productId': 'com.novaralabs.longnote.annual',
      'isTrial': false,
      'expiresAtMs': DateTime(2027, 11, 17).millisecondsSinceEpoch,
    };
    store.renewInto = 'com.novaralabs.longnote.monthly';
    final b = await boot();
    await pumpEventQueue();
    expect(b.entitlement.value.switchesToPlanId,
        'com.novaralabs.longnote.monthly');
    // A later refresh keeps it until the network says otherwise.
    await b.refresh();
    expect(b.entitlement.value.switchesToPlanId,
        'com.novaralabs.longnote.monthly');
  });

  test('store prices are cached for the next (offline) launch', () async {
    await boot();
    await pumpEventQueue();
    storePlans.clear();
    store.productsFail = true;
    final b2 = StoreKitBillingService(kv: env.kv);
    await b2.init();
    expect(planForId('com.novaralabs.longnote.annual').priceLabel, '₹5,900');
    expect(b2.trialEligible, isTrue);
  });

  test('auto-renew off shows as cancelled (willRenew false)', () async {
    store.status = {
      'active': true,
      'productId': 'com.novaralabs.longnote.annual',
      'isTrial': false,
      'expiresAtMs': DateTime(2027, 11, 17).millisecondsSinceEpoch,
    };
    store.willRenew = false;
    final b = await boot();
    await pumpEventQueue();
    expect(b.entitlement.value.isActive, isTrue);
    expect(b.entitlement.value.willRenew, isFalse);
  });

  test('native "changed" (renewal, Ask to Buy approval) refreshes', () async {
    final b = await boot();
    expect(b.entitlement.value.isActive, isFalse);
    store.status = {
      'active': true,
      'productId': 'com.novaralabs.longnote.monthly',
      'isTrial': false,
      'expiresAtMs': DateTime(2026, 12, 17).millisecondsSinceEpoch,
    };
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
            'longnote/store',
            const StandardMethodCodec()
                .encodeMethodCall(const MethodCall('changed')),
            (_) {});
    await pumpEventQueue();
    expect(b.entitlement.value.status, EntitlementStatus.active);
  });

  test('the last known plan survives a slow StoreKit at the next launch',
      () async {
    store.status = {
      'active': true,
      'productId': 'com.novaralabs.longnote.annual',
      'isTrial': false,
      'expiresAtMs': DateTime(2027, 11, 17).millisecondsSinceEpoch,
    };
    await boot();
    // Next launch: StoreKit never answers.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ch, (call) => Completer<Object?>().future);
    final b2 = StoreKitBillingService(
        kv: env.kv, statusTimeout: const Duration(milliseconds: 50));
    await b2.init();
    expect(b2.entitlement.value.status, EntitlementStatus.active);
    expect(b2.trialEligible, isFalse);
  });

  test('mapping ignores unknown products and periods', () {
    expect(
        planFromStore({
          'id': 'com.novaralabs.longnote.monthly',
          'displayPrice': r'$9.99',
          'price': 9.99,
          'periodUnit': 'week',
        }),
        isNull);
    expect(entitlementFromStore({'active': false}, trialEligible: false).trialUsed,
        isTrue);
  });
}
