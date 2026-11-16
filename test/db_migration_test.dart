import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/db/app_database.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/notes/search.dart';
import 'package:longnote/core/recording/recording_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory dir;
  late String path;
  setUp(() {
    sqfliteFfiInit();
    dir = Directory.systemTemp.createTempSync('longnote_mig_');
    path = p.join(dir.path, 'longnote.db');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// A database exactly like build 104 left it, with one processed note.
  Future<void> makeV1() async {
    final db = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) => AppDatabase.createV1ForTest(db)));
    await db.insert('recordings', {
      'id': 'old-1',
      'title': 'Budget review',
      'created_at': DateTime(2026, 11, 15).millisecondsSinceEpoch,
      'status': 'completed',
      'duration_ms': 120000,
      'segment_count': 1,
      'processing_status': 'done',
    });
    await db.insert('segments', {
      'recording_id': 'old-1', 'idx': 0, 'file_name': 'seg_0000.wav',
      'data_bytes': 3840000, 'closed': 1, 'transcribed': 1,
    });
    await db.insert('transcript_lines', {
      'recording_id': 'old-1', 'seg_idx': 0, 'start_ms': 0, 'end_ms': 4000,
      'text': 'We agreed to cut the marketing spend.', 'speaker': null,
    });
    await db.insert('summaries', {
      'recording_id': 'old-1',
      'json': '{"key_points":["Referral programme gets the money"],"decisions":[],"action_items":[],"numbers_and_dates":[],"open_questions":[]}',
      'engine': 'local',
      'created_at': 1,
    });
    await db.insert('gaps', {
      'recording_id': 'old-1', 'at_ms': 60000, 'started_at': 1, 'ended_at': 2,
      'reason': 'phone call',
    });
    await db.insert('kv', {'key': 'onboarding_done', 'value': '1'});
    await db.close();
  }

  test('v1 -> v2 keeps every note, line, summary, gap and setting', () async {
    await makeV1();
    final adb = await AppDatabase.open(factory: databaseFactoryFfi, path: path);
    final repo = RecordingRepository(adb.db, RecordingStorage(dir.path));
    expect(await adb.db.getVersion(), AppDatabase.version);

    final r = (await repo.get('old-1'))!;
    expect(r.title, 'Budget review');
    expect(r.durationMs, 120000);
    expect(r.processingStatus, ProcessingStatus.done);
    // New options are NULL = follow the settings.
    expect(r.language, isNull);
    expect(r.summaryStyle, isNull);
    expect(r.transcriptionMode, isNull);
    expect(r.source, 'recorded');
    expect(r.tries, 0);

    expect((await repo.segments('old-1')).single.transcribed, isTrue);
    final lines = await repo.transcript('old-1');
    expect(lines.single.text, contains('marketing'));
    expect(lines.single.language, isNull);
    expect(await repo.summary('old-1'), isNotNull);
    expect(await repo.gaps('old-1'), hasLength(1));
    expect(await KvStore(adb.db).getBool('onboarding_done'), isTrue);

    // New tables exist and are usable.
    for (final t in ['speakers', 'moments', 'chat_messages', 'cloud_pieces']) {
      expect(await adb.db.query(t), isEmpty);
    }

    // Old content is searchable right after the upgrade.
    expect(adb.ftsEnabled, isTrue);
    final search = NoteSearch(repo, ftsEnabled: adb.ftsEnabled);
    expect((await search.search('budget')).single.hits.first.kind,
        SearchHitKind.title);
    expect((await search.search('referral')).single.hits.single.kind,
        SearchHitKind.summary);
    expect((await search.search('marketing')).single.hits.single.kind,
        SearchHitKind.transcript);
    await adb.close();
  });

  test('a fresh install creates v2 directly', () async {
    final adb = await AppDatabase.open(factory: databaseFactoryFfi, path: path);
    expect(await adb.db.getVersion(), 2);
    final cols = (await adb.db.rawQuery('PRAGMA table_info(recordings)'))
        .map((c) => c['name'])
        .toSet();
    expect(cols, containsAll(['language', 'summary_style', 'custom_instructions',
      'output_language', 'transcription_mode', 'progress', 'error_code', 'tries']));
    await adb.close();
  });

  test('reopening a v2 database changes nothing', () async {
    await makeV1();
    (await AppDatabase.open(factory: databaseFactoryFfi, path: path)).close();
    final adb = await AppDatabase.open(factory: databaseFactoryFfi, path: path);
    expect(await adb.db.query('recordings'), hasLength(1));
    expect(await adb.db.rawQuery('SELECT * FROM notes_fts'), hasLength(1));
    await adb.close();
  });
}
