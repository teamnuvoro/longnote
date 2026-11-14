import 'package:longnote/core/summary/summarizer.dart';
import 'package:longnote/core/summary/summary_models.dart';

class UnavailableSummarizer implements Summarizer {
  UnavailableSummarizer(this.id);
  @override
  final String id;
  @override
  String get label => id;
  @override
  int get maxChunkChars => 1000;
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<MeetingSummary> summarizeChunk(String c,
          {required int part, required int parts}) =>
      throw StateError('unavailable');
}

class ScriptedSummarizer implements Summarizer {
  ScriptedSummarizer(this.id, this.reply, {this.maxChunkChars = 100});
  @override
  final String id;
  final String Function(String chunk, int part) reply;
  @override
  final int maxChunkChars;
  final calls = <String>[];
  @override
  String get label => id;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<MeetingSummary> summarizeChunk(String c,
      {required int part, required int parts}) async {
    calls.add(c);
    return MeetingSummary.parse(reply(c, part));
  }
}

