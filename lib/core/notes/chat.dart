import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../recording/recording_repository.dart';

/// A tap-to-seek source of an Ask answer: who spoke and when.
class AskSource {
  const AskSource({required this.speaker, required this.startMs});
  final String speaker;
  final int startMs;

  Map<String, Object?> toJson() => {'speaker': speaker, 'start_ms': startMs};

  /// Lenient: start_ms may come as a double or a string.
  static AskSource? tryParse(Object? v) {
    if (v is! Map) return null;
    final ms = v['start_ms'];
    final start = ms is num ? ms.toInt() : int.tryParse('$ms');
    if (start == null) return null;
    return AskSource(speaker: '${v['speaker'] ?? ''}', startMs: start);
  }
}

enum ChatRole { user, assistant }

class ChatMessage {
  const ChatMessage({
    this.id,
    required this.recordingId,
    required this.role,
    required this.text,
    this.sources = const [],
    this.found,
    required this.createdAt,
  });

  final int? id;
  final String recordingId;
  final ChatRole role;
  final String text;
  final List<AskSource> sources;

  /// Assistant only: false when the recording does not cover the question.
  final bool? found;
  final DateTime createdAt;

  Map<String, Object?> toMap() => {
        'recording_id': recordingId,
        'role': role.name,
        'text': text,
        'sources':
            sources.isEmpty ? null : jsonEncode(sources.map((s) => s.toJson()).toList()),
        'found': found == null ? null : (found! ? 1 : 0),
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory ChatMessage.fromMap(Map<String, Object?> m) {
    var sources = const <AskSource>[];
    final raw = m['sources'] as String?;
    if (raw != null) {
      try {
        final l = jsonDecode(raw);
        if (l is List) sources = [for (final e in l) ?AskSource.tryParse(e)];
      } catch (_) {}
    }
    return ChatMessage(
      id: m['id'] as int?,
      recordingId: m['recording_id'] as String,
      role: m['role'] == 'assistant' ? ChatRole.assistant : ChatRole.user,
      text: m['text'] as String,
      sources: sources,
      found: m['found'] == null ? null : m['found'] == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
    );
  }
}

/// Ask chat history per note (E2).
class ChatStore {
  ChatStore(this.repo);
  final RecordingRepository repo;
  Database get _db => repo.db;

  Future<ChatMessage> add(ChatMessage m) async {
    final id = await _db.insert('chat_messages', m.toMap());
    repo.changed();
    return ChatMessage(
        id: id,
        recordingId: m.recordingId,
        role: m.role,
        text: m.text,
        sources: m.sources,
        found: m.found,
        createdAt: m.createdAt);
  }

  Future<List<ChatMessage>> list(String recordingId) async => (await _db.query(
          'chat_messages',
          where: 'recording_id = ?',
          whereArgs: [recordingId],
          orderBy: 'created_at ASC, id ASC'))
      .map(ChatMessage.fromMap)
      .toList();

  Future<void> clear(String recordingId) async {
    await _db.delete('chat_messages',
        where: 'recording_id = ?', whereArgs: [recordingId]);
    repo.changed();
  }
}
