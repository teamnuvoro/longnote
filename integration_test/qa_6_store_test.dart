// Simulator QA run 6: a fresh install with the microphone DENIED (the host
// revoked it with `simctl privacy` before launch, so iOS shows no prompt and
// answers "denied") and REAL App Store billing (LN_BILLING=store, StoreKit 2
// against the sandbox). Nothing is bought: Apple's purchase sheet is a
// system dialog a test cannot tap. The owner buys once on TestFlight.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/billing/storekit_billing_service.dart';
import 'package:longnote/core/recording/recording_controller.dart';
import 'package:longnote/features/notes/notes_screen.dart';
import 'package:longnote/features/onboarding/onboarding_screen.dart';
import 'package:longnote/features/paywall/paywall_screen.dart';
import 'package:longnote/features/recording/recording_screen.dart';

import 'support/qa_harness.dart';

void main() {
  qaRunTest('QA run 6: microphone denied, real App Store', (qa) async {
    const first = 'First open with the microphone denied';
    const store = 'Real App Store subscriptions';

    await qa.check('N1', 'Fresh install opens onboarding (real microphone source)',
        () async {
      await qa.launch(realMic: true);
      await qa.expectOnTop<OnboardingScreen>();
    }, section: first);

    await qa.check('N2', '"Allow microphone" while iOS denies it: no crash, the '
        'screen explains iPhone Settings, Continue goes on to the paywall',
        () async {
      await qa.tap(find.text('Continue'));
      await qa.waitFor(find.text('Where your audio goes'));
      await qa.tap(find.text('Continue'));
      await qa.tap(find.text('Allow microphone'));
      await qa.waitFor(
          find.textContaining('turn the microphone on later in iPhone Settings'),
          what: 'the "turn it on in Settings" message',
          timeout: const Duration(seconds: 20));
      await qa.shot('mic-denied-onboarding');
      await qa.tap(find.text('Continue'));
      await qa.expectOnTop<PaywallScreen>();
    }, section: first, needs: ['N1']);

    await qa.check('S1', 'The app uses real App Store billing: no "simulated" '
        'note; Restore purchase, Terms and Privacy are on the paywall', () async {
      expect(qa.services.billing, isA<StoreKitBillingService>());
      expect(find.textContaining('simulated'), findsNothing);
      expect(find.text('Restore purchase'), findsOneWidget);
      expect(find.text('Terms'), findsOneWidget);
      expect(find.text('Privacy'), findsOneWidget);
    }, section: store, needs: ['N2']);

    await qa.check('S2', 'Both subscriptions load from the App Store with '
        'price, period and the 3-day free trial', () async {
      final b = qa.services.billing;
      List<Plan> plans = const [];
      await qa.waitUntil(() async {
        plans = await b.loadPlans();
        return plans.length == 2;
      }, what: 'the two App Store products', timeout: const Duration(seconds: 60),
          every: const Duration(seconds: 5));
      qa.note('store: ${plans.map((p) => '${p.id} ${p.priceLabel}/${p.periodWord} '
          'trial ${p.trialDays}d').join('; ')}; trial eligible: ${b.trialEligible}');
      for (final p in plans) {
        expect(p.trialDays, 3, reason: '${p.id} free trial');
      }
      expect(plans.first.period, PlanPeriod.year);
      expect(b.trialEligible, isTrue, reason: 'a fresh Apple ID gets the trial');
      expect(b.entitlement.value.isActive, isFalse);
      await qa.wait(const Duration(seconds: 1));
      await qa.shot('paywall-store-prices');
    }, section: store, needs: ['S1']);

    await qa.check('S3', 'The paywall shows the App Store prices and the trial '
        'button', () async {
      final yearly = storePlans['com.novaralabs.longnote.annual']!;
      expect(find.textContaining(yearly.priceLabel), findsWidgets);
      expect(find.text('Start free trial'), findsOneWidget);
    }, section: store, needs: ['S2']);

    await qa.check('N3', 'Close the paywall: Notes', () async {
      await qa.tap(byLabel('Close'));
      await qa.expectOnTop<NotesScreen>();
    }, section: first, needs: ['N2']);

    await qa.check('N4', 'Record, then Start with the microphone denied: a clear '
        'message, nothing recorded, no crash', () async {
      await qa.tap(find.text('Record'));
      await qa.expectOnTop<RecordingScreen>();
      await qa.tap(find.byKey(const ValueKey('record-start')));
      await qa.waitFor(find.textContaining('Microphone is off'),
          what: 'the "Microphone is off" message',
          timeout: const Duration(seconds: 15));
      await qa.shot('mic-denied-start');
      expect(qa.services.recorder.state, CaptureState.idle);
      expect(await qa.services.repo.all(), isEmpty);
    }, section: first, needs: ['N3']);
  });
}
