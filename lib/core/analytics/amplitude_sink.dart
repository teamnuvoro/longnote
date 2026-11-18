import 'package:amplitude_flutter/amplitude.dart';
import 'package:amplitude_flutter/autocapture/autocapture.dart';
import 'package:amplitude_flutter/configuration.dart';
import 'package:amplitude_flutter/constants.dart';
import 'package:amplitude_flutter/events/base_event.dart';
import 'package:amplitude_flutter/events/revenue.dart';
import 'package:amplitude_flutter/tracking_options.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'analytics.dart';
import 'remote_analytics.dart';

/// Amplitude project 909345 (US). The API key is public by design (it ships
/// in every app); it comes from `--dart-define=AMPLITUDE_API_KEY=...` at build
/// time (GitHub secret AMPLITUDE_API_KEY). The Amplitude SECRET key is never
/// in the app: deletion requests ("Delete my data") must run server-side.
///
/// TODO(delete-my-data): when Settings > Privacy > "Delete my data" is
/// built, a Supabase function (holding the Amplitude secret key) must call
/// Amplitude's User Privacy API for this user id + device id. Do not call it
/// from the app.
class AmplitudeSink implements AnalyticsSink {
  AmplitudeSink._(this._amp);

  final Amplitude _amp;

  static const apiKey = String.fromEnvironment('AMPLITUDE_API_KEY');
  static bool get isConfigured => apiKey.isNotEmpty;

  /// Privacy settings promised in launch/privacy-policy.md section 6:
  /// no IP address (so no city/DMA/region either), no IDFV (the device id
  /// is a random UUID), no carrier. IDFA is never collected: the iOS SDK
  /// only reads it through an optional plugin we do not add.
  static Configuration configuration(String key, {required bool optOut}) =>
      Configuration(
        apiKey: key,
        serverZone: ServerZone.us,
        optOut: optOut,
        logLevel: kReleaseMode ? LogLevel.off : LogLevel.warn,
        trackingOptions: TrackingOptions(
          ipAddress: false,
          city: false,
          dma: false,
          region: false,
          carrier: false,
          idfv: false,
          adid: false,
          appSetId: false,
          latLag: false,
        ),
        // Session start/end + app installed/updated/opened. No screen views
        // (we send our own events) and no deep links.
        autocapture: AutocaptureOptions(
          sessions: true,
          appLifecycles: true,
          screenViews: false,
          deepLinks: false,
        ),
        locationListening: false,
      );

  /// [channel] lets tests check what is sent to the native SDK.
  static Future<AmplitudeSink> create(
      {required bool enabled, String key = apiKey, MethodChannel? channel}) async {
    final amp = Amplitude(configuration(key, optOut: !enabled), channel);
    // Never hold up app start for analytics.
    await amp.isBuilt
        .timeout(const Duration(seconds: 3), onTimeout: () => false);
    return AmplitudeSink._(amp);
  }

  @override
  Future<void> track(String name, Map<String, Object> props) async {
    try {
      await _amp.track(BaseEvent(name, eventProperties: props));
      if (name == AnalyticsEvent.subscriptionPurchased) {
        final price = props['price'];
        if (price is num) {
          final r = Revenue()
            ..price = price.toDouble()
            ..quantity = 1
            ..productId = props['plan'] as String?
            ..revenueCurrency = props['currency'] as String?
            ..revenueType = 'subscription';
          await _amp.revenue(r);
        }
      }
    } catch (e) {
      debugPrint('amplitude: $e');
    }
  }

  @override
  Future<void> setUserId(String? userId) async {
    try {
      await _amp.setUserId(userId);
    } catch (_) {}
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    try {
      await _amp.setOptOut(!enabled);
    } catch (_) {}
  }
}
