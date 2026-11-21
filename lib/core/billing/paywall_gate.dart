import '../config.dart';
import '../db/app_database.dart';
import 'billing_service.dart';

/// Paywall placement rule (decided, 1.0.1):
/// - A user with no plan and no trial can record [AppConfig.freeSeconds]
///   (30 s) in total, with the transcript and summary of that note.
/// - When the 30 s run out DURING a recording, capture pauses and the
///   paywall opens ("free_limit"). Subscribe or start the trial: the same
///   recording resumes. Close it: the recording is saved and processed.
/// - With the 30 s used, Record opens the paywall first.
/// - Import is Pro only (a free import could be hours long).
/// - Viewing, playing, sharing and exporting existing notes is never
///   blocked.
/// 1.0 gave one free recording of any length: anyone who used it
/// ([legacyFreeUsedKey] >= 1) has no free seconds left.
class PaywallGate {
  PaywallGate(this.kv);
  final KvStore kv;

  static const freeSecondsKey = 'free_seconds_used';
  static const legacyFreeUsedKey = 'free_recordings_used';

  Future<int> freeSecondsUsed() async {
    if (await kv.getInt(legacyFreeUsedKey) >= 1) {
      return AppConfig.freeSeconds.inSeconds;
    }
    return kv.getInt(freeSecondsKey);
  }

  /// Free recording time still left (zero or more).
  Future<Duration> freeLeft() async => remaining(await freeSecondsUsed());

  static Duration remaining(int usedSeconds) {
    final left = AppConfig.freeSeconds.inSeconds - usedSeconds;
    return Duration(seconds: left < 0 ? 0 : left);
  }

  /// Pure rule, unit-tested. Less than one second left counts as none.
  static bool canStartRecording({
    required int freeSecondsUsed,
    required Entitlement entitlement,
  }) =>
      entitlement.isActive ||
      remaining(freeSecondsUsed) >= const Duration(seconds: 1);

  Future<bool> canStart(Entitlement e) async => canStartRecording(
      freeSecondsUsed: await freeSecondsUsed(), entitlement: e);

  /// Called when a recording ends (stopped or recovered) or an import is
  /// done: a user without a plan spends its length from the free seconds.
  Future<void> onRecordingFinished(Duration length,
      {required bool wasEntitled}) async {
    if (wasEntitled || length <= Duration.zero) return;
    // Rounded up: many sub-second recordings must not be free.
    final used =
        await freeSecondsUsed() + (length.inMilliseconds / 1000).ceil();
    final cap = AppConfig.freeSeconds.inSeconds;
    await kv.setInt(freeSecondsKey, used > cap ? cap : used);
  }
}
