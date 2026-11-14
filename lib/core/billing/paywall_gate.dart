import '../config.dart';
import '../db/app_database.dart';
import 'billing_service.dart';

/// Paywall placement rule (decided):
/// - After onboarding the user gets ONE free recording of any length, with
///   its full transcript and summary.
/// - The paywall shows when they try to START the second recording.
/// - Viewing, playing, sharing and exporting existing recordings is never
///   blocked.
/// - A recording shorter than [AppConfig.freeRecordingMinLength] (a mis-tap,
///   or a crash in the first seconds) does not use up the free recording.
class PaywallGate {
  PaywallGate(this.kv);
  final KvStore kv;

  static const freeUsedKey = 'free_recordings_used';
  static const freeAllowance = 1;

  Future<int> freeUsed() => kv.getInt(freeUsedKey);

  /// Pure rule, unit-tested.
  static bool canStartRecording({
    required int freeRecordingsUsed,
    required Entitlement entitlement,
  }) =>
      entitlement.isActive || freeRecordingsUsed < freeAllowance;

  Future<bool> canStart(Entitlement e) async =>
      canStartRecording(freeRecordingsUsed: await freeUsed(), entitlement: e);

  /// Called when a recording ends (stopped or recovered).
  Future<void> onRecordingFinished(Duration length,
      {required bool wasEntitled}) async {
    if (wasEntitled) return;
    if (length < AppConfig.freeRecordingMinLength) return;
    await kv.setInt(freeUsedKey, await freeUsed() + 1);
  }
}
