/// App-wide constants and build-time configuration.
///
/// Values that differ per build (cloud URL) come from `--dart-define`, so no
/// secret or endpoint is hard-coded. The app never holds an AI provider key.
class AppConfig {
  AppConfig._();

  static const String appName = 'Longnote';

  // ---- Audio capture -------------------------------------------------------
  /// Whisper wants 16 kHz mono PCM16, so we record exactly that.
  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int bitsPerSample = 16;
  static const int bytesPerSecond = sampleRate * channels * (bitsPerSample ~/ 8);

  /// One WAV file per 5 minutes of audio (9.6 MB each).
  static const Duration segmentLength = Duration(minutes: 5);
  static int get segmentBytes => bytesPerSecond * segmentLength.inSeconds;

  /// fsync the open segment at least this often (crash loses at most ~1 s).
  static const Duration flushInterval = Duration(seconds: 1);

  /// Heartbeat written to the database while recording.
  static const Duration heartbeatInterval = Duration(seconds: 5);

  /// A recording shorter than this does not use up the free recording.
  static const Duration freeRecordingMinLength = Duration(seconds: 30);

  // ---- Processing ----------------------------------------------------------
  static const int maxAutoAttempts = 4;
  static const Duration retryBaseDelay = Duration(seconds: 10);
  static const Duration retryMaxDelay = Duration(minutes: 10);

  // ---- Backend --------------------------------------------------------------
  // Supabase URL + anon key: lib/core/cloud/backend_config.dart (overridable
  // with --dart-define SUPABASE_URL / SUPABASE_ANON_KEY). No AI key ever
  // ships in the app.

  // ---- Billing --------------------------------------------------------------
  static const int trialDays = 3;

  /// Reminder lead time before the trial converts. The brief asks for "1 day
  /// before". Apple may charge up to 24 h before the period ends, so we send it
  /// 26 h before to make sure the reminder arrives before any charge.
  static const Duration trialReminderLead = Duration(hours: 26);
}
