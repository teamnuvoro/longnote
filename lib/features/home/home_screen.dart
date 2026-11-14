import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/models/recording.dart';
import '../../core/recording/recording_controller.dart';
import '../../core/recording/recording_repository.dart';
import '../../core/util/clock.dart';
import '../../theme.dart';
import '../detail/detail_screen.dart';
import '../paywall/paywall_screen.dart';
import '../recording/recording_screen.dart';
import '../settings/settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _showRecovered = true;

  Future<void> _onRecordPressed() async {
    final s = context.read<AppServices>();
    final rec = s.recorder;
    if (rec.isActive) {
      _openRecording();
      return;
    }
    if (!await s.canStartRecording()) {
      if (!mounted) return;
      final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
          fullscreenDialog: true, builder: (_) => const PaywallScreen()));
      if (ok != true) return;
    }
    try {
      await s.startRecording();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().contains('permission')
              ? 'Microphone is off. Turn it on in iPhone Settings > Longnote.'
              : 'Could not start recording: $e')));
      return;
    }
    _openRecording();
  }

  void _openRecording() {
    Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true, builder: (_) => const RecordingScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final recorder = context.watch<RecordingController>();
    final recovered = s.recoveredAtLaunch.where((r) => r.durationMs > 0).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Longnote'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_showRecovered && recovered.isNotEmpty)
            MaterialBanner(
              leading: const Icon(Icons.restore),
              content: Text(recovered.length == 1
                  ? 'The app closed while recording. We kept what was saved: ${formatMinutes(recovered.first.duration)}.'
                  : 'The app closed while recording. We kept what was saved in ${recovered.length} recordings.'),
              actions: [
                TextButton(
                    onPressed: () => setState(() => _showRecovered = false),
                    child: const Text('OK')),
              ],
            ),
          if (recorder.isActive)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.fiber_manual_record, color: recordRed),
                title: Text(recorder.state == CaptureState.paused
                    ? 'Recording paused'
                    : 'Recording now'),
                subtitle: Text(formatDuration(recorder.elapsed)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openRecording,
              ),
            ),
          const Expanded(child: _RecordingList()),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _RecordButton(
        active: recorder.isActive,
        onPressed: _onRecordPressed,
      ),
    );
  }
}

/// Listens only to the repository (not to the 150 ms level meter).
class _RecordingList extends StatefulWidget {
  const _RecordingList();
  @override
  State<_RecordingList> createState() => _RecordingListState();
}

class _RecordingListState extends State<_RecordingList> {
  late RecordingRepository _repo;
  Future<List<Recording>>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _repo = context.read<RecordingRepository>();
    _repo.removeListener(_reload);
    _repo.addListener(_reload);
    _future ??= _repo.all();
  }

  void _reload() {
    if (mounted) setState(() => _future = _repo.all());
  }

  @override
  void dispose() {
    _repo.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Recording>>(
      future: _future,
      builder: (context, snap) {
        final items = snap.data;
        if (items == null) return const SizedBox.shrink();
        final visible = items.where((r) => !r.status.isLive).toList();
        if (visible.isEmpty) return const _EmptyState();
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 140, top: 8),
          itemCount: visible.length,
          itemBuilder: (_, i) => _RecordingTile(r: visible[i]),
        );
      },
    );
  }
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.active, required this.onPressed});
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: active ? 'Open the recording in progress' : 'Start recording',
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: recordRed,
            boxShadow: [
              BoxShadow(
                  color: recordRed.withValues(alpha: 0.35),
                  blurRadius: 18,
                  offset: const Offset(0, 6)),
            ],
          ),
          child: Icon(active ? Icons.graphic_eq : Icons.mic,
              color: Colors.white, size: 40),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text('No recordings yet', style: t.titleMedium),
            const SizedBox(height: 8),
            Text('Tap the red button to start. You can lock the screen while it records.',
                textAlign: TextAlign.center, style: t.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _RecordingTile extends StatelessWidget {
  const _RecordingTile({required this.r});
  final Recording r;

  @override
  Widget build(BuildContext context) {
    final d = r.createdAt;
    final date =
        '${d.day}/${d.month}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return Card(
      child: ListTile(
        title: Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('$date  ·  ${formatMinutes(r.duration)}'),
              ...statusChips(context, r),
            ],
          ),
        ),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => DetailScreen(recordingId: r.id))),
      ),
    );
  }
}

/// Status chips shared by Home and Detail.
List<Widget> statusChips(BuildContext context, Recording r) {
  final cs = Theme.of(context).colorScheme;
  Widget chip(String label, Color bg, Color fg, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: bg, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, color: fg)),
        ]),
      );
  final out = <Widget>[];
  if (r.status == RecordingStatus.interrupted) {
    out.add(chip('Interrupted', cs.tertiaryContainer, cs.onTertiaryContainer,
        Icons.warning_amber_rounded));
  }
  switch (r.processingStatus) {
    case ProcessingStatus.queued:
    case ProcessingStatus.transcribing:
    case ProcessingStatus.summarizing:
      out.add(chip(r.processingProgress ?? 'Waiting to process',
          cs.secondaryContainer, cs.onSecondaryContainer, Icons.hourglass_top));
    case ProcessingStatus.failed:
      out.add(chip('Processing failed - audio is safe', cs.errorContainer,
          cs.onErrorContainer, Icons.error_outline));
    case ProcessingStatus.done:
      out.add(chip('Notes ready', cs.primaryContainer, cs.onPrimaryContainer,
          Icons.check));
    case ProcessingStatus.none:
      break;
  }
  return out;
}
