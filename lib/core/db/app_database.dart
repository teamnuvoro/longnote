import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../summary/summary_models.dart';

/// Opens the single app database. Tests pass a `databaseFactoryFfi` and
/// `inMemoryDatabasePath`.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  /// 1 = v0.1 (15 Nov). 2 = v1 build (16 Nov): note options, pipeline state,
  /// speakers, cloud pieces, moments, chat, full-text search.
  static const int version = 2;

  /// False when this SQLite has no FTS5; search then falls back to LIKE.
  bool get ftsEnabled => _ftsEnabled;
  bool _ftsEnabled = true;

  static Future<AppDatabase> open({
    required DatabaseFactory factory,
    required String path,
  }) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, v) async {
          await _createV1(db);
          await _upgradeToV2(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) await _upgradeToV2(db);
        },
      ),
    );
    final out = AppDatabase._(db);
    out._ftsEnabled = await _hasTable(db, 'turns_fts');
    return out;
  }

  static Future<bool> _hasTable(Database db, String name) async =>
      (await db.rawQuery(
              "SELECT 1 FROM sqlite_master WHERE name = ?", [name]))
          .isNotEmpty;

  /// Builds the v1 schema on [db] (migration tests only).
  @visibleForTesting
  static Future<void> createV1ForTest(Database db) => _createV1(db);

  /// The v1 schema exactly as shipped in build 104. Never change it; add a
  /// new `_upgradeToVn` step instead.
  static Future<void> _createV1(Database db) async {
    final b = db.batch();
    b.execute('''
      CREATE TABLE recordings (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        status TEXT NOT NULL,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        segment_count INTEGER NOT NULL DEFAULT 0,
        heartbeat_at INTEGER,
        note TEXT,
        processing_status TEXT NOT NULL DEFAULT 'none',
        processing_error TEXT,
        processing_progress TEXT
      )''');
    b.execute('''
      CREATE TABLE segments (
        recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
        idx INTEGER NOT NULL,
        file_name TEXT NOT NULL,
        data_bytes INTEGER NOT NULL DEFAULT 0,
        closed INTEGER NOT NULL DEFAULT 0,
        transcribed INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (recording_id, idx)
      )''');
    b.execute('''
      CREATE TABLE gaps (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
        at_ms INTEGER NOT NULL,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        reason TEXT NOT NULL
      )''');
    b.execute('''
      CREATE TABLE transcript_lines (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
        seg_idx INTEGER NOT NULL,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        text TEXT NOT NULL,
        speaker TEXT
      )''');
    b.execute(
        'CREATE INDEX idx_lines_rec ON transcript_lines(recording_id, start_ms)');
    b.execute('''
      CREATE TABLE summaries (
        recording_id TEXT PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
        json TEXT NOT NULL,
        engine TEXT NOT NULL,
        note TEXT,
        created_at INTEGER NOT NULL
      )''');
    b.execute('''
      CREATE TABLE jobs (
        recording_id TEXT PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
        state TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER NOT NULL,
        last_error TEXT,
        updated_at INTEGER NOT NULL
      )''');
    b.execute('''
      CREATE TABLE events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        ts INTEGER NOT NULL,
        recording_id TEXT,
        props TEXT
      )''');
    b.execute('CREATE INDEX idx_events_name ON events(name, ts)');
    b.execute('''
      CREATE TABLE kv (
        key TEXT PRIMARY KEY,
        value TEXT
      )''');
    await b.commit(noResult: true);
  }

  /// v1 -> v2. Keeps every existing note, transcript line and summary.
  static Future<void> _upgradeToV2(Database db) async {
    final b = db.batch();
    // ---- note options + pipeline state (NULL option = use the setting) ----
    for (final col in const [
      'language TEXT', // 'auto' or a code ('en', 'hi', 'pt-BR')
      'summary_style TEXT', // SummaryStyle.id
      'custom_instructions TEXT',
      'output_language TEXT', // 'same' or a language name ('English')
      'transcription_mode TEXT', // 'cloud' | 'on_device'; NULL = setting
      'transcript_source TEXT', // who wrote transcript_lines: 'cloud' | 'on_device'
      "source TEXT NOT NULL DEFAULT 'recorded'", // 'recorded' | 'imported'
      'import_file TEXT', // imported audio, relative to the note folder
      'progress REAL', // 0..1 for uploading / transcribing
      'error_code TEXT', // server/pipeline error code of the last failure
      'tries INTEGER NOT NULL DEFAULT 0',
      'updated_at INTEGER',
    ]) {
      b.execute('ALTER TABLE recordings ADD COLUMN $col');
    }
    // ---- transcript turns: transcript_lines gains the language -----------
    // transcript_lines IS the turns table: (recording_id, speaker = speaker
    // key, start_ms, end_ms, text). seg_idx = WAV part (on-device) or cloud
    // piece index (cloud).
    b.execute('ALTER TABLE transcript_lines ADD COLUMN language TEXT');
    b.execute(
        'CREATE INDEX idx_lines_speaker ON transcript_lines(recording_id, speaker)');
    b.execute('ALTER TABLE summaries ADD COLUMN style TEXT');
    b.execute('''
      CREATE TABLE speakers (
        recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
        speaker_key TEXT NOT NULL,
        display_name TEXT NOT NULL,
        color_index INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (recording_id, speaker_key)
      )''');
    b.execute('''
      CREATE TABLE moments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
        at_ms INTEGER NOT NULL,
        label TEXT,
        created_at INTEGER NOT NULL
      )''');
    b.execute('CREATE INDEX idx_moments_rec ON moments(recording_id, at_ms)');
    b.execute('''
      CREATE TABLE chat_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        text TEXT NOT NULL,
        sources TEXT,
        found INTEGER,
        created_at INTEGER NOT NULL
      )''');
    b.execute(
        'CREATE INDEX idx_chat_rec ON chat_messages(recording_id, created_at)');
    // One row per audio piece sent to the server (1 piece up to 5 h; 4-h
    // pieces above that). All upload/job state lives here so it survives
    // restarts.
    b.execute('''
      CREATE TABLE cloud_pieces (
        recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
        idx INTEGER NOT NULL,
        client_id TEXT NOT NULL,
        inputs TEXT NOT NULL,
        range_start_ms INTEGER NOT NULL DEFAULT 0,
        start_ms INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        audio_file TEXT,
        audio_bytes INTEGER,
        audio_ms INTEGER,
        user_id TEXT,
        upload_url TEXT,
        upload_created_at INTEGER,
        uploaded INTEGER NOT NULL DEFAULT 0,
        server_job_id TEXT,
        poll_started_at INTEGER,
        transcribed INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (recording_id, idx)
      )''');
    await b.commit(noResult: true);

    await _createSearch(db);
  }

  /// Full-text search (FTS5): titles + summaries in `notes_fts`, transcript
  /// turns in `turns_fts` (external content = transcript_lines, kept in sync
  /// by triggers). If this SQLite lacks FTS5, search uses LIKE instead.
  static Future<void> _createSearch(Database db) async {
    const tok = "tokenize = 'unicode61 remove_diacritics 2'";
    try {
      await db.execute(
          'CREATE VIRTUAL TABLE notes_fts USING fts5(recording_id UNINDEXED, title, summary, $tok)');
      await db.execute(
          "CREATE VIRTUAL TABLE turns_fts USING fts5(text, content='transcript_lines', content_rowid='id', $tok)");
    } catch (e) {
      debugPrint('FTS5 not available, search falls back to LIKE: $e');
      try {
        await db.execute('DROP TABLE IF EXISTS notes_fts');
      } catch (_) {}
      return;
    }
    final b = db.batch();
    b.execute('''
      CREATE TRIGGER lines_ai AFTER INSERT ON transcript_lines BEGIN
        INSERT INTO turns_fts(rowid, text) VALUES (new.id, new.text);
      END''');
    b.execute('''
      CREATE TRIGGER lines_ad AFTER DELETE ON transcript_lines BEGIN
        INSERT INTO turns_fts(turns_fts, rowid, text) VALUES ('delete', old.id, old.text);
      END''');
    b.execute('''
      CREATE TRIGGER lines_au AFTER UPDATE OF text ON transcript_lines BEGIN
        INSERT INTO turns_fts(turns_fts, rowid, text) VALUES ('delete', old.id, old.text);
        INSERT INTO turns_fts(rowid, text) VALUES (new.id, new.text);
      END''');
    b.execute('''
      CREATE TRIGGER rec_ai AFTER INSERT ON recordings BEGIN
        INSERT INTO notes_fts(recording_id, title, summary) VALUES (new.id, new.title, '');
      END''');
    b.execute('''
      CREATE TRIGGER rec_au AFTER UPDATE OF title ON recordings BEGIN
        UPDATE notes_fts SET title = new.title WHERE recording_id = new.id;
      END''');
    b.execute('''
      CREATE TRIGGER rec_ad AFTER DELETE ON recordings BEGIN
        DELETE FROM notes_fts WHERE recording_id = old.id;
      END''');
    // Backfill what v1 already holds.
    b.execute("INSERT INTO turns_fts(turns_fts) VALUES ('rebuild')");
    b.execute(
        "INSERT INTO notes_fts(recording_id, title, summary) SELECT id, title, '' FROM recordings");
    await b.commit(noResult: true);
    final sums = await db.query('summaries', columns: ['recording_id', 'json']);
    for (final r in sums) {
      await db.update('notes_fts', {'summary': summaryPlainText(r['json'] as String?)},
          where: 'recording_id = ?', whereArgs: [r['recording_id']]);
    }
  }

  Future<void> close() => db.close();
}

/// Tiny key/value settings store in the same database.
class KvStore {
  KvStore(this._db);
  final Database _db;

  Future<String?> get(String key) async {
    final r = await _db.query('kv', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  Future<void> set(String key, String? value) => _db.insert(
      'kv', {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<bool> getBool(String key, {bool fallback = false}) async {
    final v = await get(key);
    return v == null ? fallback : v == '1';
  }

  Future<void> setBool(String key, bool v) => set(key, v ? '1' : '0');

  Future<int> getInt(String key, {int fallback = 0}) async =>
      int.tryParse(await get(key) ?? '') ?? fallback;

  Future<void> setInt(String key, int v) => set(key, '$v');
}

/// Searchable text of a stored summary JSON ('' if it cannot be read).
String summaryPlainText(String? json) {
  if (json == null || json.isEmpty) return '';
  try {
    return MeetingSummary.parse(json).toPlainText();
  } catch (_) {
    return '';
  }
}
