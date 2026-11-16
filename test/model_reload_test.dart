import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/features/note/note_model.dart';
import 'package:longnote/features/notes/notes_screen.dart';

import 'helpers/test_env.dart';

/// Regression for the TestFlight 105 freeze: progress updates arriving while
/// the note / notes screen was reloading spun the microtask queue forever
/// (the database reply could never arrive), freezing the app.
void main() {
  late TestEnv env;
  setUp(() async {
    env = await TestEnv.create();
    await env.repo.insert(Recording(
        id: 'n1', title: 't', createdAt: env.clock.now(),
        status: RecordingStatus.completed, durationMs: 8000));
  });
  tearDown(() async => env.dispose());

  Future<void> hammer() async {
    for (var i = 0; i < 40; i++) {
      // Not awaited on purpose: changes land while a reload is in flight.
      unawaited(env.repo.setProcessing('n1', ProcessingStatus.transcribing,
          progress: 'Transcribing $i'));
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await env.repo.setProcessing('n1', ProcessingStatus.summarizing,
        progress: 'Writing summary');
  }

  test('NoteModel keeps up with rapid progress updates', () async {
    final m = NoteModel(env.repo, 'n1');
    await hammer().timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 200))
        .timeout(const Duration(seconds: 5));
    expect(m.data?.note.processingStatus, ProcessingStatus.summarizing);
    m.dispose();
  });

  test('NotesModel keeps up with rapid progress updates', () async {
    final m = NotesModel(env.repo);
    await hammer().timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 200))
        .timeout(const Duration(seconds: 5));
    expect(m.notes?.single.processingStatus, ProcessingStatus.summarizing);
    m.dispose();
  });
}
