import 'package:facebook_app_events/facebook_app_events.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'analytics.dart';
import 'remote_analytics.dart';

/// The part of the Meta (Facebook) App Events SDK we use, so tests can
/// fake it ([FacebookMetaEvents] is the real one).
abstract class MetaEvents {
  Future<void> initializeSdk();
  Future<void> activateApp();
  Future<void> setAutoLogMetaDataEnabled(bool enabled);
  Future<void> setAdvertiserIdCollectionEnabled(bool enabled);
  Future<void> logCompletedRegistration();
  Future<void> logStartTrial({String? currency, required String orderId});
  Future<void> logSubscribe(
      {double? price, String? currency, required String orderId});
}

class FacebookMetaEvents implements MetaEvents {
  FacebookMetaEvents([FacebookAppEvents? fb]) : _fb = fb ?? FacebookAppEvents();
  final FacebookAppEvents _fb;

  @override
  Future<void> initializeSdk() => _fb.initializeSdk();
  @override
  Future<void> activateApp() => _fb.activateApp();
  @override
  Future<void> setAutoLogMetaDataEnabled(bool enabled) =>
      _fb.setAutoLogMetaDataEnabled(enabled);
  @override
  Future<void> setAdvertiserIdCollectionEnabled(bool enabled) =>
      _fb.setAdvertiserIdCollectionEnabled(enabled);
  @override
  Future<void> logCompletedRegistration() => _fb.logCompletedRegistration();
  @override
  Future<void> logStartTrial({String? currency, required String orderId}) =>
      _fb.logStartTrial(currency: currency, orderId: orderId);
  @override
  Future<void> logSubscribe(
          {double? price, String? currency, required String orderId}) =>
      _fb.logSubscribe(price: price, currency: currency, orderId: orderId);
}

/// Meta App Events, for ad measurement only (which ad brought an install,
/// a trial or a subscription). Sends only four things: app activation,
/// CompleteRegistration (onboarding finished), StartTrial and Subscribe. No
/// other event, no user id, no note content.
///
/// The SDK is held back until the app decides (Info.plist
/// FacebookAutoInitEnabled = false, FacebookAutoLogAppEventsEnabled = false):
/// so the "Share usage analytics" switch stops Meta too, and Meta's own
/// automatic in-app-purchase logging cannot double count our events.
/// The IDFA is collected only after the user allowed tracking (ATT).
///
/// App ID and client token: Info.plist, written at build time from the
/// GitHub secrets META_APP_ID / META_CLIENT_TOKEN (see the workflows). The
/// Dart side is switched on by `--dart-define=META_APP_ID=...`; without it
/// (local builds, tests, simulator QA) Meta is never touched.
class MetaSink implements AnalyticsSink {
  MetaSink(this._meta, {required bool enabled, required bool attAuthorized})
      : _enabled = enabled,
        _attAuthorized = attAuthorized;

  final MetaEvents _meta;
  bool _enabled;
  bool _attAuthorized;
  bool _started = false;

  static const appId = String.fromEnvironment('META_APP_ID');
  static bool get isConfigured => appId.isNotEmpty;

  bool get started => _started;
  bool get advertiserIdCollection => _attAuthorized;

  /// Our event name -> Meta standard event. Nothing else is sent to Meta.
  static const forwarded = {
    AnalyticsEvent.onboardingCompleted,
    AnalyticsEvent.trialStarted,
    AnalyticsEvent.subscriptionPurchased,
  };

  /// Initializes the SDK (only while enabled) and logs app activation.
  /// Called at launch and each time the app comes back on screen.
  Future<void> activate() async {
    if (!_enabled) return;
    try {
      if (!_started) {
        await _meta.initializeSdk();
        // Pinned SDK 18.0.3 has no metadata collection (no-op); kept so a
        // future SDK 19+ (which attaches screen titles / URLs) stays off.
        await _meta.setAutoLogMetaDataEnabled(false);
        await _meta.setAdvertiserIdCollectionEnabled(_attAuthorized);
        _started = true;
      }
      await _meta.activateApp();
    } catch (e) {
      debugPrint('meta activate: $e');
    }
  }

  /// The App Tracking Transparency answer: IDFA only when authorized.
  Future<void> setAttAuthorized(bool authorized) async {
    _attAuthorized = authorized;
    if (!_started) return;
    try {
      await _meta.setAdvertiserIdCollectionEnabled(authorized);
    } catch (e) {
      debugPrint('meta advertiser id: $e');
    }
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    if (enabled) await activate();
  }

  /// Meta gets no user id: ad measurement does not need ours.
  @override
  Future<void> setUserId(String? userId) async {}

  @override
  Future<void> track(String name, Map<String, Object> props) async {
    if (!_enabled || !forwarded.contains(name)) return;
    if (!_started) await activate();
    if (!_started) return;
    final currency = props['currency'] as String?;
    // A fresh id per event: Meta must not merge two people's purchases.
    final orderId = const Uuid().v4();
    try {
      switch (name) {
        case AnalyticsEvent.onboardingCompleted:
          await _meta.logCompletedRegistration();
        case AnalyticsEvent.trialStarted:
          // No value: a free trial is not revenue.
          await _meta.logStartTrial(currency: currency, orderId: orderId);
        case AnalyticsEvent.subscriptionPurchased:
          final price = props['price'];
          await _meta.logSubscribe(
              price: price is num ? price.toDouble() : null,
              currency: currency,
              orderId: orderId);
      }
    } catch (e) {
      debugPrint('meta $name: $e');
    }
  }
}
