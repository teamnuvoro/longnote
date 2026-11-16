import '../cloud/cloud_pieces.dart';
import '../cloud/cloud_pipeline.dart';
import '../models/recording.dart';
import '../recording/recording_repository.dart';
import '../settings/app_settings.dart';
import 'job_queue.dart';
import 'processing_pipeline.dart';

/// The queue's [JobProcessor]: sends a note down the cloud pipeline or the
/// on-device (whisper) pipeline, per the note's override or the setting.
class NoteProcessor {
  NoteProcessor({
    required this.repo,
    required this.settings,
    required this.onDevice,
    required this.pieces,
    this.cloud,
  });

  final RecordingRepository repo;
  final AppSettings settings;
  final ProcessingPipeline onDevice;
  final CloudPieceStore pieces;

  /// Null when the backend is not configured in this build.
  final CloudPipeline? cloud;

  Future<TranscriptionMode> modeFor(Recording? note) async {
    // Imports are cloud-only (the phone engine reads recorded WAV parts).
    if (note?.source == 'imported' && cloud != null) {
      return TranscriptionMode.cloud;
    }
    final m = note?.transcriptionMode ?? await settings.transcriptionMode();
    return m == TranscriptionMode.cloud && cloud == null
        ? TranscriptionMode.onDevice
        : m;
  }

  Future<void> process(String id, void Function(String) onProgress) async {
    final note = await repo.get(id);
    if (await modeFor(note) == TranscriptionMode.cloud) {
      return cloud!.process(id, onProgress);
    }
    if (note?.transcriptSource == 'cloud') {
      // Switching a cloud note to the phone: start the transcript over.
      await repo.clearTranscript(id);
      await pieces.deleteAll(id);
    }
    await repo.setTranscriptSource(id, 'on_device');
    await onDevice.process(id, onProgress);
  }

  /// "Transcribe on this phone instead" (D8): whisper, no speakers.
  Future<void> transcribeOnPhoneInstead(String id, ProcessingJobQueue queue) async {
    await repo.setNoteOptions(id, transcriptionMode: TranscriptionMode.onDevice);
    await queue.enqueue(id);
  }
}
