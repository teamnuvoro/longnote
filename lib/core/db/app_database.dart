import 'package:sqflite/sqflite.dart';

/// Opens the single app database. Tests pass a `databaseFactoryFfi` and
/// `inMemoryDatabasePath`.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const int version = 1;

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
        onCreate: (db, v) async => _create(db),
      ),
    );
    return AppDatabase._(db);
  }

  static Future<void> _create(Database db) async {
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
