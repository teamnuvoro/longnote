import '../db/app_database.dart';
import '../models/recording.dart';
import '../summary/summary_style.dart';

/// User settings (G1-G3), stored in the `kv` table. New notes take these as
/// defaults; a note can override language/style/output language/mode.
class AppSettings {
  AppSettings(this.kv);
  final KvStore kv;

  static const _audioLanguage = 'set_audio_language';
  static const _summaryLanguage = 'set_summary_language';
  static const _style = 'set_summary_style';
  static const _speakerLabels = 'set_speaker_labels';
  static const _mode = 'set_transcription_mode';
  static const _excludeBackup = 'set_exclude_from_icloud_backup';

  /// 'auto' or a code (see lib/core/notes/languages.dart).
  Future<String> audioLanguage() async => await kv.get(_audioLanguage) ?? 'auto';
  Future<void> setAudioLanguage(String code) => kv.set(_audioLanguage, code);

  /// 'same' or a language name ('English', 'Hindi').
  Future<String> summaryLanguage() async =>
      await kv.get(_summaryLanguage) ?? 'same';
  Future<void> setSummaryLanguage(String v) => kv.set(_summaryLanguage, v);

  Future<SummaryStyle> defaultStyle() async =>
      SummaryStyle.parse(await kv.get(_style));
  Future<void> setDefaultStyle(SummaryStyle s) => kv.set(_style, s.id);

  /// Show speaker names in transcripts (D3 toggle default).
  Future<bool> speakerLabels() => kv.getBool(_speakerLabels, fallback: true);
  Future<void> setSpeakerLabels(bool v) => kv.setBool(_speakerLabels, v);

  /// Cloud (Soniox, with speakers) is the default; on-device = whisper.
  Future<TranscriptionMode> transcriptionMode() async =>
      TranscriptionMode.parse(await kv.get(_mode)) ?? TranscriptionMode.cloud;
  Future<void> setTranscriptionMode(TranscriptionMode m) => kv.set(_mode, m.id);

  /// Keep recordings out of iCloud device backups (off by default: a phone
  /// restore should bring the recordings back).
  Future<bool> excludeFromBackup() => kv.getBool(_excludeBackup);
  Future<void> setExcludeFromBackup(bool v) => kv.setBool(_excludeBackup, v);
}
