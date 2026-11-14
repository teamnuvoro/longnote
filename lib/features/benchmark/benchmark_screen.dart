import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/billing/billing_service.dart';
import '../../core/billing/paywall_gate.dart';
import '../../core/models/recording.dart';
import '../../core/util/clock.dart';

/// Result of one benchmark run.
class BenchmarkResult {
  BenchmarkResult({
    required this.model,
    required this.audio,
    required this.wall,
    required this.batteryBefore,
    required this.batteryAfter,
    required this.lines,
    required this.parts,
    this.error,
  });
  final String model;
  final Duration audio;
  final Duration wall;
  final int? batteryBefore;
  final int? batteryAfter;
  final int lines;
  final int parts;
  final String? error;

  /// Real-time factor: wall time / audio time. 0.1 = 10x faster than real time.
  double get rtf =>
      audio.inMilliseconds == 0 ? 0 : wall.inMilliseconds / audio.inMilliseconds;

  String toReport() => [
        'Longnote benchmark',
        'Model: $model',
        'Audio length: ${formatDuration(audio)} ($parts parts)',
        'Transcription wall time: ${formatDuration(wall)}',
        'Real-time factor: ${rtf.toStringAsFixed(3)} (lower is faster; ${rtf == 0 ? '-' : '${(1 / rtf).toStringAsFixed(1)}x real time'})',
        'Battery before: ${batteryBefore ?? '?'}%',
        'Battery after: ${batteryAfter ?? '?'}%',
        'Lines produced: $lines',
        if (error != null) 'Error: $error',
        'Run at: ${DateTime.now().toIso8601String()}',
      ].join('\n');
}

/// Hidden screen (Settings > tap the version 7 times). Week-1 device test:
/// transcribe a chosen recording and report speed and battery. Results are
/// not saved as the recording's transcript.
class BenchmarkScreen extends StatefulWidget {
  const BenchmarkScreen({super.key});
  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<BenchmarkScreen> {
  List<Recording> _recs = const [];
  Recording? _chosen;
  bool _running = false;
  String _progress = '';
  BenchmarkResult? _result;
  bool _fake = false;

  AppServices get _s => context.read<AppServices>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final all = (await _s.repo.all()).where((r) => r.durationMs > 0 && !r.status.isLive).toList();
      final last = await _s.kv.get('benchmark_last');
      if (!mounted) return;
      setState(() {
        _recs = all;
        _chosen = all.isEmpty ? null : all.first;
        _fake = _s.useFakeTranscriber;
        if (last != null) _progress = 'Last run:\n$last';
      });
    });
  }

  Future<int?> _battery() async {
    try {
      return await Battery().batteryLevel;
    } catch (_) {
      return null;
    }
  }

  Future<void> _run() async {
    final r = _chosen;
    if (r == null) return;
    setState(() {
      _running = true;
      _result = null;
      _progress = 'Preparing model...';
    });
    final t = _s.currentTranscriber();
    String? error;
    var lines = 0;
    final segs = (await _s.repo.segments(r.id)).where((s) => s.dataBytes > 0).toList();
    final audio = Duration(milliseconds: segs.fold(0, (a, s) => a + s.durationMs));
    final before = await _battery();
    final sw = Stopwatch();
    try {
      await t.ensureReady(
          onProgress: (p) => setState(() => _progress = 'Downloading model ${(p * 100).round()}% (not timed)'));
      sw.start();
      var offset = 0;
      for (var i = 0; i < segs.length; i++) {
        setState(() => _progress = 'Transcribing part ${i + 1} of ${segs.length}...');
        final out = await t.transcribeFile(
            _s.repo.storage.segmentPath(r.id, segs[i].fileName),
            offsetMs: offset,
            segmentIndex: segs[i].index);
        lines += out.length;
        offset += segs[i].durationMs;
      }
    } catch (e) {
      error = e.toString();
    }
    sw.stop();
    try {
      await t.releaseResources();
    } catch (_) {}
    final after = await _battery();
    final res = BenchmarkResult(
      model: t.name,
      audio: audio,
      wall: sw.elapsed,
      batteryBefore: before,
      batteryAfter: after,
      lines: lines,
      parts: segs.length,
      error: error,
    );
    await _s.kv.set('benchmark_last', res.toReport());
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = res;
      _progress = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Benchmark')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Transcribes one recording on this phone and reports speed and battery. '
            'For a fair battery number: unplug, close other apps, use a recording of 30+ minutes. '
            'Keep the screen on (iOS pauses work in the background).',
            style: t.bodyMedium,
          ),
          const SizedBox(height: 16),
          if (_recs.isEmpty)
            const Text('Make a recording first.')
          else
            DropdownButton<Recording>(
              isExpanded: true,
              value: _chosen,
              items: [
                for (final r in _recs)
                  DropdownMenuItem(
                      value: r,
                      child: Text('${r.title} (${formatMinutes(r.duration)})',
                          overflow: TextOverflow.ellipsis)),
              ],
              onChanged: _running ? null : (v) => setState(() => _chosen = v),
            ),
          const SizedBox(height: 8),
          Text('Model: ${_s.currentTranscriber().name}', style: t.bodySmall),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _running || _chosen == null ? null : _run,
            child: Text(_running ? 'Running...' : 'Run benchmark'),
          ),
          const SizedBox(height: 16),
          if (_progress.isNotEmpty) Text(_progress),
          if (_result != null) ...[
            SelectableText(_result!.toReport(), style: t.bodyMedium?.copyWith(fontFamily: 'Courier')),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy results'),
              onPressed: () => Clipboard.setData(ClipboardData(text: _result!.toReport())),
            ),
          ],
          const Divider(height: 40),
          Text('Developer', style: t.titleSmall),
          SwitchListTile(
            title: const Text('Use fake transcriber'),
            subtitle: const Text('For UI testing on the simulator. Produces placeholder text.'),
            value: _fake,
            onChanged: (v) async {
              _s.useFakeTranscriber = v;
              await _s.kv.setBool(AppServices.kvFakeTranscriber, v);
              setState(() => _fake = v);
            },
          ),
          ListTile(
            title: const Text('Reset test billing + free recording'),
            subtitle: const Text('Back to a fresh install\'s plan state.'),
            onTap: () async {
              final b = _s.billing;
              if (b is FakeBillingService) await b.resetForDev();
              await _s.kv.setInt(PaywallGate.freeUsedKey, 0);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Reset done.')));
              }
            },
          ),
        ],
      ),
    );
  }
}
