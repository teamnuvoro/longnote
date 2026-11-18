import 'dart:async';

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/widgets.dart';

/// Apple's App Tracking Transparency status (our own enum, so the rest of
/// the app and the tests do not depend on the plugin).
enum AttStatus { notDetermined, restricted, denied, authorized, notSupported }

/// The ATT prompt behind an interface: tests and simulator QA use
/// [NoTrackingConsent] / a fake, so no system dialog ever blocks them.
abstract class TrackingConsent {
  Future<AttStatus> status();

  /// Shows Apple's "Allow tracking?" prompt (iOS shows it at most once per
  /// install; later calls return the stored answer).
  Future<AttStatus> request();
}

/// The real prompt (app_tracking_transparency). Text:
/// Info.plist NSUserTrackingUsageDescription.
class AppleTrackingConsent implements TrackingConsent {
  const AppleTrackingConsent();

  @override
  Future<AttStatus> status() async {
    try {
      return _map(await AppTrackingTransparency.trackingAuthorizationStatus);
    } catch (_) {
      return AttStatus.notSupported;
    }
  }

  @override
  Future<AttStatus> request() async {
    try {
      // iOS drops the request (answer: notDetermined, no prompt) unless the
      // app is fully active, e.g. while the microphone dialog is closing.
      await _untilActive(const Duration(seconds: 3));
      return _map(await AppTrackingTransparency.requestTrackingAuthorization());
    } catch (_) {
      return AttStatus.notSupported;
    }
  }

  static Future<void> _untilActive(Duration max) async {
    final b = WidgetsBinding.instance;
    if (b.lifecycleState == AppLifecycleState.resumed) {
      // A short pause after a system dialog closes.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return;
    }
    final done = Completer<void>();
    final l = AppLifecycleListener(onResume: () {
      if (!done.isCompleted) done.complete();
    });
    try {
      await done.future.timeout(max, onTimeout: () {});
      await Future<void>.delayed(const Duration(milliseconds: 400));
    } finally {
      l.dispose();
    }
  }

  static AttStatus _map(TrackingStatus s) => switch (s) {
        TrackingStatus.notDetermined => AttStatus.notDetermined,
        TrackingStatus.restricted => AttStatus.restricted,
        TrackingStatus.denied => AttStatus.denied,
        TrackingStatus.authorized => AttStatus.authorized,
        TrackingStatus.notSupported => AttStatus.notSupported,
      };
}

/// Never asks. Used when Meta is not in the build (local builds, tests)
/// or with `--dart-define=LN_TRACKING=off` (simulator QA).
class NoTrackingConsent implements TrackingConsent {
  const NoTrackingConsent();
  @override
  Future<AttStatus> status() async => AttStatus.notSupported;
  @override
  Future<AttStatus> request() async => AttStatus.notSupported;
}
