import '../cloud/longnote_api.dart';
import '../recording/recording_repository.dart';
import 'chat.dart';
import 'speakers.dart';

/// Ask about one note (E1/E2): sends its turns (with the user's speaker
/// names), the question and the last messages; stores both sides.
class AskService {
  AskService({required this.repo, required this.api, DateTime Function()? now})
      : chat = ChatStore(repo),
        speakers = SpeakerStore(repo),
        _now = now ?? DateTime.now;

  final RecordingRepository repo;
  final LongnoteApi api;
  final ChatStore chat;
  final SpeakerStore speakers;
  final DateTime Function() _now;

  static const maxQuestionChars = 1000;
  static const historyMessages = 6;

  /// Stores the question, asks, stores and returns the answer. On failure the
  /// question stays stored and the error is thrown (the UI offers "Try again").
  Future<ChatMessage> ask(String recordingId, String question) async {
    final q = question.trim();
    if (q.isEmpty) throw ArgumentError('empty question');
    final clipped = q.length > maxQuestionChars ? q.substring(0, maxQuestionChars) : q;
    final before = await chat.list(recordingId);
    await chat.add(ChatMessage(
        recordingId: recordingId,
        role: ChatRole.user,
        text: clipped,
        createdAt: _now()));
    return answer(recordingId, clipped, before);
  }

  /// Asks again for a question that is already stored (retry after an error).
  Future<ChatMessage> answer(
      String recordingId, String question, List<ChatMessage> history) async {
    final names = await speakers.names(recordingId);
    final turns = [
      for (final l in await repo.transcript(recordingId))
        {
          'speaker': l.speaker == null
              ? 'Speaker'
              : (names[l.speaker] ?? 'Speaker ${l.speaker}'),
          'start_ms': l.startMs,
          'text': l.text,
        }
    ];
    final h = history.length > historyMessages
        ? history.sublist(history.length - historyMessages)
        : history;
    final reply = await api.ask(
      turns: turns,
      question: question,
      history: [
        for (final m in h) {'role': m.role.name, 'content': m.text}
      ],
    );
    return chat.add(ChatMessage(
      recordingId: recordingId,
      role: ChatRole.assistant,
      text: reply.answer,
      sources: reply.sources,
      found: reply.found,
      createdAt: _now(),
    ));
  }
}
