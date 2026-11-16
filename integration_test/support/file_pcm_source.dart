// A microphone for the simulator QA suite: plays a 16 kHz mono PCM16 WAV
// file from the HOST disk (simulator apps can read host paths) into the real
// recorder, paced in real time, with input levels. After the file ends it
// sends silence, like a quiet room. Lives in integration_test/ only: nothing
// here (or any test audio) is in the release app.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:longnote/core/audio/pcm_source.dart';
import 'package:longnote/core/config.dart';

class FilePcmSource implements PcmSource {
  FilePcmSource(this.path);

  /// The file the NEXT recording plays (the test sets it before tapping
  /// Record). Null = silence.
  static String? nextPath;

  /// The source of the live recording (to check pause/resume from the test).
  static FilePcmSource? current;

  /// Bytes of real audio (not silence) sent by all sources this run.
  static int audioBytesSent = 0;

  /// Audio seconds sent per real second. 1 = real time. The long-recording
  /// check uses more so an hour of audio takes minutes; the recorder's timer
  /// counts the bytes it is given, so it shows the full hour.
  static int speed = 1;

  final String? path;
  static const _tick = Duration(milliseconds: 100);

  Uint8List _pcm = Uint8List(0);
  int _pos = 0; // next byte of [_pcm] to send
  StreamController<Uint8List>? _out;
  final _levels = StreamController<double>.broadcast();
  final _paused = StreamController<bool>.broadcast();
  final _interruptions = StreamController<InterruptionPhase>.broadcast();
  Timer? _timer;
  final _clock = Stopwatch();
  int _sentBytes = 0; // bytes sent since start (audio + silence)
  bool isPaused = false;

  /// Bytes of the file left to play.
  int get remainingBytes => math.max(0, _pcm.length - _pos);
  bool get finished => _pos >= _pcm.length;

  /// Reads the samples of a PCM16 WAV (any chunk layout, e.g. afconvert's
  /// FLLR padding chunk).
  static Uint8List readWavPcm(String path) {
    final b = File(path).readAsBytesSync();
    final d = ByteData.sublistView(b);
    String id(int o) => String.fromCharCodes(b.sublist(o, o + 4));
    if (b.length < 12 || id(0) != 'RIFF' || id(8) != 'WAVE') {
      throw FormatException('not a WAV file: $path');
    }
    var o = 12;
    while (o + 8 <= b.length) {
      final size = d.getUint32(o + 4, Endian.little);
      if (id(o) == 'fmt ') {
        final channels = d.getUint16(o + 10, Endian.little);
        final rate = d.getUint32(o + 12, Endian.little);
        final bits = d.getUint16(o + 22, Endian.little);
        if (channels != AppConfig.channels ||
            rate != AppConfig.sampleRate ||
            bits != AppConfig.bitsPerSample) {
          throw FormatException(
              'need 16 kHz mono PCM16, got $rate Hz x$channels $bits-bit: $path');
        }
      }
      if (id(o) == 'data') {
        final end = math.min(b.length, o + 8 + size);
        return Uint8List.sublistView(b, o + 8, end - ((end - o - 8) % 2));
      }
      o += 8 + size + (size % 2);
    }
    throw FormatException('no data chunk: $path');
  }

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<Stream<Uint8List>> start() async {
    final p = path;
    _pcm = p == null ? Uint8List(0) : readWavPcm(p);
    _pos = 0;
    _sentBytes = 0;
    current = this;
    _out = StreamController<Uint8List>();
    _clock
      ..reset()
      ..start();
    _timer = Timer.periodic(_tick, (_) => _pump());
    return _out!.stream;
  }

  /// Sends what real time says is due (timers drift; the stopwatch does not).
  void _pump() {
    final out = _out;
    if (out == null || out.isClosed || isPaused) return;
    final due = (_clock.elapsedMicroseconds * speed * AppConfig.bytesPerSecond ~/
            1000000) &
        ~1;
    var n = due - _sentBytes;
    if (n <= 0) return;
    final chunk = Uint8List(n);
    final fromFile = math.min(n, remainingBytes);
    if (fromFile > 0) {
      chunk.setRange(0, fromFile, _pcm, _pos);
      _pos += fromFile;
      audioBytesSent += fromFile;
    }
    _sentBytes += n;
    out.add(chunk);
    _levels.add(_dbfs(chunk));
  }

  static double _dbfs(Uint8List pcm) {
    final d = ByteData.sublistView(pcm);
    var sum = 0.0;
    final samples = pcm.length ~/ 2;
    if (samples == 0) return -60;
    for (var i = 0; i < samples; i++) {
      final v = d.getInt16(i * 2, Endian.little) / 32768.0;
      sum += v * v;
    }
    final rms = math.sqrt(sum / samples);
    if (rms <= 0.001) return -60;
    return math.max(-60, 20 * math.log(rms) / math.ln10);
  }

  @override
  Future<void> pause() async {
    if (isPaused) return;
    isPaused = true;
    _clock.stop();
    _paused.add(true);
  }

  @override
  Future<void> resume() async {
    if (!isPaused) return;
    isPaused = false;
    _clock.start();
    _paused.add(false);
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
    // Not awaited: close() waits for a listener that may already be gone.
    unawaited(_out?.close());
    _out = null;
    if (identical(current, this)) current = null;
  }

  /// Like an incoming phone call on iOS: the input stops, then the session
  /// sends "interruption began".
  void interruptBegin() {
    isPaused = true;
    _clock.stop();
    _interruptions.add(InterruptionPhase.began);
  }

  /// The call ended. Resumable: iOS says the app may go on (the recorder
  /// calls [resume]). Not resumable: the input stays stopped until the user
  /// taps Resume.
  void interruptEnd({bool resumable = true}) {
    _interruptions.add(resumable
        ? InterruptionPhase.endedResumable
        : InterruptionPhase.endedNotResumable);
  }

  @override
  Stream<double> levels() => _levels.stream;

  @override
  Stream<InterruptionPhase> interruptions() => _interruptions.stream;

  @override
  Stream<bool> pausedChanges() => _paused.stream;

  @override
  void dispose() {
    _timer?.cancel();
    _levels.close();
    _paused.close();
    _interruptions.close();
  }
}
