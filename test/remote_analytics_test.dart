// Amplitude + Meta forwarding, the "Share usage analytics" switch, the PII
// rules and the App Tracking Transparency prompt. Everything here is fake:
// no network, no platform SDK, no system dialog.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/app_services.dart';
import 'package:longnote/core/analytics/amplitude_sink.dart';
import 'package:longnote/core/analytics/analytics.dart';
import 'package:longnote/core/analytics/meta_sink.dart';
import 'package:longnote/core/analytics/remote_analytics.dart';
import 'package:longnote/core/analytics/tracking_consent.dart';
import 'package:longnote/core/billing/billing_service.dart';

import 'helpers/fake_analytics.dart';
import 'helpers/test_env.dart';

/// Keys the privacy policy promises never to send (section 6).
const _forbidden = [
  'title',
  'text',
  'transcript',
  'summary',
  'name',
  'note_title',
  'noteTitle',
  'file_name',
  'fileName',
  'transcript_text',
  'summary_text',
  'speaker_name',
  'question',
  'path',
];

void expectNoPii(Iterable<(String, Map<String, Object>)> events) {
  for (final (name, props) in events) {
    for (final k in props.keys) {
      expect(isPiiKey(k), isFalse, reason: '$name carries "$k"');
      for (final f in ['title', 'transcript', 'summary', 'text', 'name']) {
        expect(k.toLowerCase().contains(f), isFalse,
            reason: '$name carries "$k"');
      }
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  Analytics analyticsWith(List<AnalyticsSink> sinks, {bool enabled = true}) =>
      Analytics(env.db.db, clock: env.clock, sinks: sinks, remoteEnabled: enabled);

  Future<AppServices> services(
      {required Analytics analytics,
      TrackingConsent tracking = const NoTrackingConsent(),
      MetaSink? meta}) async {
    final billing = FakeBillingService(kv: env.kv, clock: env.clock);
    await billing.init();
    return AppServices.forTesting(
      db: env.db,
      repo: env.repo,
      analytics: analytics,
      billing: billing,
      recordingsRoot: env.dir.path,
      clock: env.clock,
      tracking: tracking,
      meta: meta,
    );
  }

  group('forwarding', () {
    test('every event is kept locally AND forwarded, with its props', () async {
      final sink = FakeSink();
      final a = analyticsWith([sink]);
      for (final n in AnalyticsEvent.all) {
        await a.log(n, recordingId: 'rec-1', props: {'k': 'v', 'n': 3});
      }
      expect(sink.names, AnalyticsEvent.all);
      expect(sink.propsOf(AnalyticsEvent.export),
          {'k': 'v', 'n': 3, 'recording_id': 'rec-1'});
      expect((await a.counts()).keys.toSet(), AnalyticsEvent.all.toSet());
    });

    test('a throwing sink never breaks logging', () async {
      final a = analyticsWith([_ThrowingSink()]);
      await a.log(AnalyticsEvent.export, props: {'kind': 'pdf'});
      expect(await a.counts(), {AnalyticsEvent.export: 1});
    });

    test('user id goes to every sink', () async {
      final sink = FakeSink();
      await analyticsWith([sink]).setUserId('3f6c-anon-uuid');
      expect(sink.userIds, ['3f6c-anon-uuid']);
    });
  });

  group('no note content ever leaves the phone', () {
    test('denylisted keys are dropped, free text becomes "other"', () async {
      final sink = FakeSink();
      final a = analyticsWith([sink]);
      await a.log(AnalyticsEvent.export, props: {
        for (final k in _forbidden) k: 'Board meeting with Priya',
        'kind': 'pdf',
        'error': 'SocketException: /var/mobile/Containers/Board meeting.m4a',
        'code': 'upload_failed',
        'list': ['a'],
        'ok': true,
        'ms': 1200,
      });
      final props = sink.propsOf(AnalyticsEvent.export);
      expect(props, {
        'kind': 'pdf',
        'error': 'other',
        'code': 'upload_failed',
        'ok': true,
        'ms': 1200,
      });
      expectNoPii(sink.events);
      // The local log (never sent) keeps everything.
      final local = (await a.recent()).single.props;
      expect(local['title'], 'Board meeting with Priya');
    });

    test('isPiiKey catches snake_case and camelCase parts', () {
      for (final k in _forbidden) {
        expect(isPiiKey(k), isTrue, reason: k);
      }
      for (final k in [
        'kind', 'via', 'plan', 'price', 'currency', 'placement', 'status',
        'duration_ms', 'attempt', 'final', 'cause', 'reason', 'from', 'result'
      ]) {
        expect(isPiiKey(k), isFalse, reason: k);
      }
    });
  });

  group('Share usage analytics switch', () {
    test('off stops Amplitude-style sinks and Meta; on resumes', () async {
      final sink = FakeSink();
      final fb = FakeMetaEvents();
      final meta = MetaSink(fb, enabled: true, attAuthorized: false);
      final a = analyticsWith([sink, meta]);
      final s = await services(analytics: a, meta: meta);

      await s.setShareAnalytics(false);
      expect(await s.settings.shareAnalytics(), isFalse, reason: 'persisted');
      expect(sink.enabled, isFalse);
      await a.log(AnalyticsEvent.onboardingCompleted);
      await a.log(AnalyticsEvent.subscriptionPurchased,
          props: {'price': 59.99, 'currency': 'USD'});
      expect(sink.events, isEmpty);
      expect(fb.calls, isEmpty, reason: 'Meta never even initialized');
      await meta.activate();
      expect(fb.calls, isEmpty);
      // Still in the local log.
      expect((await a.counts())[AnalyticsEvent.onboardingCompleted], 1);

      await s.setShareAnalytics(true);
      await a.log(AnalyticsEvent.onboardingCompleted);
      expect(sink.names, [AnalyticsEvent.onboardingCompleted]);
      expect(fb.calls, contains('CompleteRegistration'));
    });

    test('defaults to on', () async {
      final s = await services(analytics: analyticsWith(const []));
      expect(await s.settings.shareAnalytics(), isTrue);
    });
  });

  group('Meta', () {
    test('starts with metadata off, IDFA off unless ATT allowed, then activates',
        () async {
      final fb = FakeMetaEvents();
      await MetaSink(fb, enabled: true, attAuthorized: false).activate();
      expect(fb.calls,
          ['init', 'metadata:false', 'advertiserId:false', 'activate']);
    });

    test('only onboarding is sent from the app (money events come from the server)',
        () async {
      final fb = FakeMetaEvents();
      final meta = MetaSink(fb, enabled: true, attAuthorized: false);
      final a = analyticsWith([meta]);
      await meta.activate();
      fb.calls.clear();
      for (final n in AnalyticsEvent.all) {
        await a.log(n, props: {'price': 9.99, 'currency': 'INR', 'plan': 'p'});
      }
      expect(fb.calls, ['CompleteRegistration']);
    });

    test('anonymous id: only while sharing is on (starts the SDK first)',
        () async {
      final fb = FakeMetaEvents();
      final meta = MetaSink(fb, enabled: false, attAuthorized: false);
      expect(await meta.anonymousId(), isNull);
      expect(fb.calls, isEmpty, reason: 'SDK never touched while off');
      await meta.setEnabled(true);
      expect(await meta.anonymousId(), 'XZTEST-ANON-1');
      fb.anonId = '';
      expect(await meta.anonymousId(), isNull);
    });

    test('advertiser id collection follows the ATT answer', () async {
      final fb = FakeMetaEvents();
      final meta = MetaSink(fb, enabled: true, attAuthorized: false);
      await meta.activate();
      expect(fb.advertiserId, isFalse);
      await meta.setAttAuthorized(true);
      expect(fb.advertiserId, isTrue);
      await meta.setAttAuthorized(false);
      expect(fb.advertiserId, isFalse);
    });
  });

  group('App Tracking Transparency', () {
    Future<(AppServices, FakeTrackingConsent, FakeMetaEvents, FakeSink)> make(
        {AttStatus current = AttStatus.notDetermined,
        AttStatus answer = AttStatus.authorized,
        bool withMeta = true}) async {
      final att = FakeTrackingConsent(current: current, answer: answer);
      final fb = FakeMetaEvents();
      final meta = withMeta
          ? MetaSink(fb, enabled: true, attAuthorized: false)
          : null;
      final sink = FakeSink();
      final s = await services(
          analytics: analyticsWith([sink, ?meta]), tracking: att, meta: meta);
      await meta?.activate();
      return (s, att, fb, sink);
    }

    test('asked once, only when not determined; IDFA follows "Allow"',
        () async {
      final (s, att, fb, sink) = await make();
      await s.askTrackingOnce();
      await s.askTrackingOnce();
      expect(att.prompts, 1);
      expect(fb.advertiserId, isTrue);
      expect(sink.propsOf(AnalyticsEvent.attResult), {'status': 'authorized'});
      expect(await s.kv.getBool(AppServices.kvAttAsked), isTrue);
    });

    test('"Ask App Not to Track" keeps the IDFA off', () async {
      final (s, att, fb, sink) = await make(answer: AttStatus.denied);
      await s.askTrackingOnce();
      expect(att.prompts, 1);
      expect(fb.advertiserId, isFalse);
      expect(sink.propsOf(AnalyticsEvent.attResult), {'status': 'denied'});
    });

    test('never prompts when iOS already has an answer', () async {
      for (final st in [
        AttStatus.denied,
        AttStatus.restricted,
        AttStatus.authorized,
        AttStatus.notSupported
      ]) {
        final (s, att, fb, sink) = await make(current: st);
        await s.askTrackingOnce();
        expect(att.prompts, 0, reason: st.name);
        expect(fb.advertiserId, st == AttStatus.authorized, reason: st.name);
        expect(sink.names, isNot(contains(AnalyticsEvent.attResult)));
        await s.kv.setBool(AppServices.kvAttAsked, false);
      }
    });

    test('a prompt iOS did not show (app not active) may be asked again',
        () async {
      final (s, att, _, sink) = await make(answer: AttStatus.notDetermined);
      await s.askTrackingOnce();
      expect(await s.kv.getBool(AppServices.kvAttAsked), isFalse);
      expect(sink.names, isNot(contains(AnalyticsEvent.attResult)));
      att.answer = AttStatus.denied;
      await s.askTrackingOnce();
      expect(att.prompts, 2);
      expect(await s.kv.getBool(AppServices.kvAttAsked), isTrue);
    });

    test('never prompts without Meta in the build (tests, QA, local)',
        () async {
      final (s, att, _, _) = await make(withMeta: false);
      await s.askTrackingOnce();
      expect(att.prompts, 0);
    });

    test('never prompts while analytics sharing is off', () async {
      final (s, att, _, _) = await make();
      await s.setShareAnalytics(false);
      await s.askTrackingOnce();
      expect(att.prompts, 0);
    });
  });

  group('purchases and restore', () {
    const inrAnnual = Plan(
        id: 'com.novaralabs.longnote.annual',
        period: PlanPeriod.year,
        price: 4999,
        priceLabel: '₹4,999',
        currency: 'INR');

    test('paid purchase -> subscription_purchased with price + currency',
        () async {
      final sink = FakeSink();
      final s = await services(analytics: analyticsWith([sink]));
      await s.logPurchase(inrAnnual, startedTrial: false);
      expect(sink.propsOf(AnalyticsEvent.subscriptionPurchased), {
        'source': 'app',
        'plan': 'com.novaralabs.longnote.annual',
        'period': 'year',
        'price': 4999.0,
        'currency': 'INR',
      });
      expect(sink.names, isNot(contains(AnalyticsEvent.trialStarted)));
    });

    test('trial -> trial_started (not a purchase)', () async {
      final sink = FakeSink();
      final s = await services(analytics: analyticsWith([sink]));
      await s.billing.purchase(annualPlan);
      await s.logPurchase(annualPlan, startedTrial: true);
      expect(sink.names, [AnalyticsEvent.trialStarted]);
      final p = sink.propsOf(AnalyticsEvent.trialStarted);
      expect(p['trial_days'], 3);
      expect(p['currency'], 'USD');
      expect(p['trial_ends_at'], isA<String>());
    });

    test('restore logs the tap and the result', () async {
      final sink = FakeSink();
      final s = await services(analytics: analyticsWith([sink]));
      final r = await s.restorePurchases('settings');
      expect(sink.names,
          [AnalyticsEvent.restoreTapped, AnalyticsEvent.restoreResult]);
      expect(sink.propsOf(AnalyticsEvent.restoreResult),
          {'from': 'settings', 'result': r.name, 'active': false});
    });
  });

  group('Amplitude SDK settings', () {
    const channel = MethodChannel('amplitude_flutter_test');
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (c) async {
        calls.add(c);
        return null;
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    test('no IP, no IDFV/IDFA, no location, US zone; opt-out follows switch',
        () async {
      await AmplitudeSink.create(
          enabled: false, key: 'test-key', channel: channel);
      final init = calls.single;
      expect(init.method, 'init');
      final cfg = (init.arguments as Map).cast<String, Object?>();
      expect(cfg['optOut'], isTrue);
      expect(cfg['serverZone'], 'us');
      final t = (cfg['trackingOptions'] as Map).cast<String, Object?>();
      for (final k in [
        'ipAddress', 'idfv', 'adid', 'city', 'dma', 'region', 'carrier',
        'latLag'
      ]) {
        expect(t[k], isFalse, reason: k);
      }
      expect(cfg['useAdvertisingIdForDeviceId'], isFalse);
    });

    test('track (no revenue from the app: the server sends it), opt-out, user id',
        () async {
      final sink = await AmplitudeSink.create(
          enabled: true, key: 'test-key', channel: channel);
      calls.clear();
      await sink.track(AnalyticsEvent.subscriptionPurchased,
          {'plan': 'com.novaralabs.longnote.monthly', 'price': 9.99, 'currency': 'USD'});
      await sink.track(AnalyticsEvent.trialStarted, {'plan': 'x', 'price': 59.99});
      await sink.setEnabled(false);
      await sink.setUserId('anon-uuid-1');
      expect(calls.map((c) => c.method),
          ['track', 'track', 'setOptOut', 'setUserId']);
      final ev = ((calls[0].arguments as Map)['event'] as Map);
      expect(ev['event_type'], 'subscription_purchased');
    });
  });
}

class _ThrowingSink implements AnalyticsSink {
  @override
  Future<void> setEnabled(bool enabled) => throw StateError('x');
  @override
  Future<void> setUserId(String? userId) => throw StateError('x');
  @override
  Future<void> track(String name, Map<String, Object> props) =>
      throw StateError('x');
}
