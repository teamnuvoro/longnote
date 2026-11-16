import '../cloud/longnote_api.dart';
import 'summarizer.dart';
import 'summary_models.dart';
import 'summary_style.dart';

/// Style, the user's own instructions and output language for one summary.
class SummaryOptions {
  const SummaryOptions({
    this.style = SummaryStyle.meeting,
    this.customInstructions,
    this.outputLanguage = 'same',
  });

  final SummaryStyle style;

  /// <= 1000 chars; preferences only, the server never lets them add facts.
  final String? customInstructions;

  /// 'same' (main language of the transcript) or a name such as 'English'.
  final String outputLanguage;
}

/// Sends transcript TEXT (never audio) to our `summarize` edge function
/// (BACKEND-API 4.3) with the signed-in user's JWT. The AI key lives only on
/// the server. Errors ([ApiException], network errors) propagate so callers
/// can retry, wait for the network, or fall back.
class CloudSummarizer implements Summarizer {
  CloudSummarizer({this.api, this.options = const SummaryOptions()});

  /// Null = not configured in this build.
  final LongnoteApi? api;
  final SummaryOptions options;

  CloudSummarizer withOptions(SummaryOptions o) =>
      CloudSummarizer(api: api, options: o);

  @override
  String get id => 'cloud';

  @override
  String get label => 'Cloud summary';

  /// The server takes up to 120,000 chars; we send 100,000 per part
  /// (a 3-hour meeting is 2 parts) and merge in Dart.
  @override
  int get maxChunkChars => 100000;

  @override
  Future<bool> isAvailable() async => api?.config.isConfigured ?? false;

  @override
  Future<MeetingSummary> summarizeChunk(String chunk,
      {required int part, required int parts}) async {
    final a = api;
    if (a == null) throw StateError('cloud summary is not configured');
    final json = await a.summarize(
      transcript: chunk,
      part: part,
      parts: parts,
      style: options.style.id,
      customInstructions: options.customInstructions,
      outputLanguage: options.outputLanguage,
    );
    return MeetingSummary.fromJson(json);
  }
}
