import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../app_services.dart';
import '../../core/analytics/analytics.dart';
import '../../core/models/recording.dart';
import '../common/screen_clock.dart';

/// File types the Files picker offers (AVFoundation reads them; for video the
/// native compress step takes the audio track: AppDelegate `AudioEncoderPlugin`).
const importExtensions = [
  'mp3', 'm4a', 'wav', 'aac', 'mp4', 'mov', 'm4v', 'caf', 'aif', 'aiff', '3gp',
];

/// A file the user picked, still where the picker put it.
class PickedMedia {
  PickedMedia({required this.path, required this.name, required this.bytes});
  final String path;
  final String name;
  final int bytes;

  /// Filled in by [ImportController.pick] (null while probing / unknown).
  int? durationMs;
  bool probed = false;

  /// audio / video, for analytics (from the extension, never the name).
  String get kind =>
      const {'mp4', 'mov', 'm4v', '3gp'}.contains(extension) ? 'video' : 'audio';

  String get extension {
    final e = p.extension(name).replaceFirst('.', '').toLowerCase();
    return e.isEmpty ? 'm4a' : e;
  }

  /// "Board meeting Nov 12.m4a" -> "Board meeting Nov 12".
  String get suggestedTitle {
    final t = p.basenameWithoutExtension(name).replaceAll('_', ' ').trim();
    return t.isEmpty ? 'Imported recording' : t;
  }
}

/// Picks files. Replaced in tests.
abstract class MediaPicker {
  /// Files app (iCloud Drive, Google Drive, Dropbox ...).
  Future<PickedMedia?> pickFile();

  /// A video from Photos (its sound is used).
  Future<PickedMedia?> pickVideo();
}

class FilePickerMediaPicker implements MediaPicker {
  const FilePickerMediaPicker();

  Future<PickedMedia?> _wrap(PlatformFile? f) async {
    final path = f?.path;
    if (f == null || path == null) return null;
    final bytes = f.lengthSync() ?? await f.length() ?? File(path).lengthSync();
    return PickedMedia(path: path, name: f.name, bytes: bytes);
  }

  @override
  Future<PickedMedia?> pickFile() async => _wrap(await FilePicker.pickFile(
      type: FileType.custom, allowedExtensions: importExtensions));

  @override
  Future<PickedMedia?> pickVideo() async =>
      _wrap(await FilePicker.pickFile(type: FileType.video));
}

/// Reads the length of an audio or video file. Replaced in tests.
abstract class MediaProbe {
  Future<int?> durationMs(String path);
}

class JustAudioProbe implements MediaProbe {
  const JustAudioProbe();
  @override
  Future<int?> durationMs(String path) async {
    final player = AudioPlayer();
    try {
      final d = await player.setFilePath(path, preload: true);
      return d?.inMilliseconds;
    } catch (_) {
      return null;
    } finally {
      unawaited(player.dispose());
    }
  }
}

enum ImportState { copying, failed }

/// One file being copied into the app (F3 card).
class ImportJob {
  ImportJob({required this.id, required this.title, required this.totalBytes});
  final String id;
  final String title;
  final int totalBytes;
  int copiedBytes = 0;
  ImportState state = ImportState.copying;
  String? error;
  bool cancelled = false;
  double get fraction => totalBytes <= 0 ? 0 : copiedBytes / totalBytes;
}

/// Import flow state shared by F1-F3 (lives as long as the app's services):
/// the picked file waiting for F2, and the copies in progress.
///
/// Import = copy the file into the note's folder with progress (cancellable),
/// read its length, then create a note (`source = imported`) and queue it for
/// the same pipeline as a recording. The original file is not touched.
class ImportController extends ChangeNotifier {
  ImportController(this.s);
  final AppServices s;

  static final _byServices = Expando<ImportController>('import');
  static ImportController of(AppServices s) =>
      _byServices[s] ??= ImportController(s);

  /// Tests replace these.
  static MediaPicker picker = const FilePickerMediaPicker();
  static MediaProbe probe = const JustAudioProbe();

  /// Picked, waiting for "Import and transcribe" (F2).
  PickedMedia? pending;
  final List<ImportJob> jobs = [];

  /// Opens the picker; returns the file (also kept in [pending]) or null.
  Future<PickedMedia?> pick({bool video = false}) async {
    final m = video ? await picker.pickVideo() : await picker.pickFile();
    if (m == null) return null;
    pending = m;
    notifyListeners();
    unawaited(() async {
      m.durationMs = await probe.durationMs(m.path);
      m.probed = true;
      notifyListeners();
    }());
    return m;
  }

  /// Copies [m] into the app and creates the note. Returns the note id, or
  /// null if it was cancelled or failed (the job then says why).
  Future<String?> start(
    PickedMedia m, {
    required String title,
    required String language,
    required String summaryStyle,
    bool forceCloud = false,
  }) async {
    final id = const Uuid().v4();
    final job = ImportJob(
        id: id,
        title: title.trim().isEmpty ? m.suggestedTitle : title.trim(),
        totalBytes: m.bytes);
    jobs.insert(0, job);
    if (identical(pending, m)) pending = null;
    notifyListeners();

    final dir = Directory(s.repo.storage.dirFor(id));
    final fileName = 'import.${m.extension}';
    // Codes only: never the file's name or title.
    final kind = {'kind': m.kind, 'format': m.extension};
    unawaited(s.analytics.log(AnalyticsEvent.importStarted, props: kind));
    final part = File(p.join(dir.path, '$fileName.part'));
    try {
      await dir.create(recursive: true);
      await _copy(File(m.path), part, job);
      if (job.cancelled) return _cancelled(job, dir, kind);
      final dest = await part.rename(p.join(dir.path, fileName));
      final ms = m.durationMs ?? await probe.durationMs(dest.path);
      if (job.cancelled) return _cancelled(job, dir, kind);
      if (ms == null || ms <= 0) {
        await _cleanup(dir);
        return _fail(job, 'We could not find any sound in this file.',
            code: 'no_sound', kind: kind);
      }
      final now = screenNow();
      await s.repo.insert(Recording(
        id: id,
        title: job.title,
        createdAt: now,
        status: RecordingStatus.completed,
        durationMs: ms,
        source: 'imported',
        importFile: fileName,
        language: language,
        summaryStyle: summaryStyle,
        outputLanguage: await s.settings.summaryLanguage(),
        transcriptionMode: forceCloud ? TranscriptionMode.cloud : null,
        updatedAt: now,
      ));
      jobs.remove(job);
      notifyListeners();
      unawaited(s.analytics.log(AnalyticsEvent.importCompleted,
          recordingId: id, props: {...kind, 'duration_s': ms ~/ 1000}));
      await s.jobs.enqueue(id);
      await s.noteQueuedByUser();
      return id;
    } on FileSystemException catch (e) {
      await _cleanup(dir);
      final full = e.osError?.errorCode == 28; // ENOSPC
      return _fail(
          job,
          full
              ? 'Your phone is out of space. Free some space and import again.'
              : 'We could not copy this file. Try again.',
          code: full ? 'disk_full' : 'copy_failed',
          kind: kind);
    } catch (_) {
      await _cleanup(dir);
      return _fail(job, 'We could not copy this file. Try again.',
          code: 'failed', kind: kind);
    }
  }

  /// The user stopped the copy (F3 "x"): import_failed with `cancelled`.
  Future<String?> _cancelled(
      ImportJob job, Directory dir, Map<String, Object?> kind) async {
    await _cleanup(dir);
    jobs.remove(job);
    notifyListeners();
    unawaited(s.analytics.log(AnalyticsEvent.importFailed,
        props: {...kind, 'error': 'cancelled'}));
    return null;
  }

  String? _fail(ImportJob job, String why,
      {required String code, required Map<String, Object?> kind}) {
    unawaited(s.analytics
        .log(AnalyticsEvent.importFailed, props: {...kind, 'error': code}));
    job
      ..state = ImportState.failed
      ..error = why;
    notifyListeners();
    return null;
  }

  /// Copies the file in chunks with every write awaited (so memory stays
  /// flat even for a multi-GB video), reporting progress every ~1 MB.
  Future<void> _copy(File from, File to, ImportJob job) async {
    final out = await to.open(mode: FileMode.write);
    var lastNotified = 0;
    try {
      await for (final chunk in from.openRead()) {
        if (job.cancelled) break;
        await out.writeFrom(chunk);
        job.copiedBytes += chunk.length;
        if (job.copiedBytes - lastNotified >= 1 << 20) {
          lastNotified = job.copiedBytes;
          notifyListeners();
        }
      }
      await out.flush();
    } finally {
      await out.close();
    }
    notifyListeners();
  }

  Future<void> _cleanup(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// F3 "x": stops the copy and removes the partial file.
  void cancel(ImportJob job) {
    if (job.state == ImportState.failed) {
      jobs.remove(job);
      notifyListeners();
      return;
    }
    job.cancelled = true;
    notifyListeners();
  }
}
