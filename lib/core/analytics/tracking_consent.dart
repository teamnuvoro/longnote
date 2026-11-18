
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

// The real prompt (AppleTrackingConsent, app_tracking_transparency) was
// removed with the plugin: v1 shows no ATT prompt (owner, 18 Nov 2026).

/// Never asks. Used when Meta is not in the build (local builds, tests)
/// or with `--dart-define=LN_TRACKING=off` (simulator QA).
class NoTrackingConsent implements TrackingConsent {
  const NoTrackingConsent();
  @override
  Future<AttStatus> status() async => AttStatus.notSupported;
  @override
  Future<AttStatus> request() async => AttStatus.notSupported;
}
