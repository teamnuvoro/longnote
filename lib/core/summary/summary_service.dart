import '../db/app_database.dart';
import 'apple_on_device_summarizer.dart';
import 'cloud_summarizer.dart';
import 'local_extractive_summarizer.dart';
import 'summarizer.dart';
import 'summary_models.dart';

enum SummaryEngine {
  /// Apple Intelligence when the phone has it, otherwise the basic offline one.
  auto('Automatic (on this phone)'),
  apple('Apple Intelligence (on this phone)'),
  cloud('Cloud (sends transcript text to our server)'),
  local('Basic offline summary');

  const SummaryEngine(this.label);
  final String label;

  static SummaryEngine parse(String? s) => SummaryEngine.values
      .firstWhere((e) => e.name == s, orElse: () => SummaryEngine.auto);
}

class SummaryOutcome {
  SummaryOutcome(this.summary, this.engineId, this.note);
  final MeetingSummary summary;
  final String engineId;

  /// Honest note when a fallback was used.
  final String? note;
}

/// Picks the summarizer from Settings and falls back to the local one when
/// the chosen engine is unavailable or fails, saying so in [SummaryOutcome.note].
class SummaryService {
  SummaryService({
    required this.kv,
    required this.apple,
    required this.cloud,
    required this.local,
  });

  final KvStore kv;
  final Summarizer apple;
  final Summarizer cloud;
  final Summarizer local;

  static const kvKey = 'summary_engine';

  Future<SummaryEngine> engine() async => SummaryEngine.parse(await kv.get(kvKey));
  Future<void> setEngine(SummaryEngine e) => kv.set(kvKey, e.name);

  factory SummaryService.standard(KvStore kv) => SummaryService(
        kv: kv,
        apple: AppleOnDeviceSummarizer(),
        cloud: CloudSummarizer(),
        local: LocalExtractiveSummarizer(),
      );

  Future<SummaryOutcome> summarize(String transcript,
      {void Function(String)? onProgress, SummaryEngine? override}) async {
    final choice = override ?? await engine();
    Summarizer? primary;
    String? unavailableNote;
    switch (choice) {
      case SummaryEngine.auto:
        if (await apple.isAvailable()) primary = apple;
      case SummaryEngine.apple:
        if (await apple.isAvailable()) {
          primary = apple;
        } else {
          unavailableNote =
              'Apple Intelligence is not available on this phone, so this is the basic offline summary.';
        }
      case SummaryEngine.cloud:
        if (await cloud.isAvailable()) {
          primary = cloud;
        } else {
          unavailableNote =
              'Cloud summary is not set up in this build, so this is the basic offline summary.';
        }
      case SummaryEngine.local:
        primary = local;
    }

    if (primary != null && primary != local) {
      try {
        final s = await summarizeLong(primary, transcript,
            onProgress: (d, t) => onProgress
                ?.call('Writing summary${t > 1 ? ' (${d + 1 > t ? t : d + 1} of $t)' : ''}'));
        if (!s.isEmpty || transcript.trim().isEmpty) {
          return SummaryOutcome(s, primary.id, null);
        }
        unavailableNote =
            '${primary.label} returned nothing, so this is the basic offline summary.';
      } catch (e) {
        unavailableNote =
            '${primary.label} failed, so this is the basic offline summary. You can try again.';
      }
    }
    onProgress?.call('Writing summary');
    final s = await summarizeLong(local, transcript);
    return SummaryOutcome(s, local.id, unavailableNote);
  }
}
