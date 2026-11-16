import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../app_services.dart';
import '../../core/models/recording.dart';
import '../../core/recording/recording_controller.dart';
import '../../core/recording/recording_repository.dart';
import '../../core/util/clock.dart';
import '../../ui/widgets.dart';

/// B1 Notes home (Figma 3:7) and B2 empty (3:141).
///
/// MINIMAL version so the app works end to end on the new shell: large
/// title, search entry, "Waiting & needs attention" list with Retry, notes
/// grouped by day, floating Record pill. The screens session finishes it
/// (exact copy, B2 artwork, swipe actions, trial chip from billing).
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  bool _showRecovered = true;

  Future<void> _onRecord() async {
    final s = context.read<AppServices>();
    if (s.recorder.isActive) {
      context.pushNamed(R.record);
      return;
    }
    if (!await s.canStartRecording()) {
      if (!mounted) return;
      final ok = await context.pushNamed<bool>(R.paywall);
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
    if (mounted) context.pushNamed(R.record);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final repo = context.watch<RecordingRepository>();
    final recorder = context.watch<RecordingController>();
    final recovered =
        s.recoveredAtLaunch.where((r) => r.durationMs > 0).toList();

    return Scaffold(
      backgroundColor: LnColors.paper,
      body: Stack(children: [
        SafeArea(
          bottom: false,
          child: FutureBuilder<(List<Recording>, Map<String, String>)>(
            future: _load(repo),
            builder: (context, snap) {
              final notes = snap.data?.$1 ?? const <Recording>[];
              final previews = snap.data?.$2 ?? const <String, String>{};
              final attention = notes
                  .where((n) => n.processingStatus.needsAttention)
                  .toList();
              final rest = notes
                  .where((n) => !n.processingStatus.needsAttention)
                  .toList();
              return ListView(
                padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
                children: [
                  const LnLargeTitle('Notes'),
                  LnSearchField(
                      readOnly: true, onTap: () => context.pushNamed(R.search)),
                  const SizedBox(height: 20),
                  if (_showRecovered && recovered.isNotEmpty) ...[
                    LnCardGroup(children: [
                      LnAttentionRow(
                        icon: LnIcons.alert,
                        title: 'The app closed while recording',
                        subtitle:
                            'We kept what was saved: ${formatMinutes(recovered.first.duration)}.',
                        actions: [
                          LnIconButton(
                            icon: LnIcons.x,
                            shape: LnIconButtonShape.square,
                            iconSize: 16,
                            onPressed: () => setState(() => _showRecovered = false),
                          )
                        ],
                      ),
                    ]),
                    const SizedBox(height: LnSpace.section),
                  ],
                  if (snap.hasData && notes.isEmpty) const _Empty(),
                  if (attention.isNotEmpty) ...[
                    LnSectionLabel('Waiting & needs attention',
                        count: attention.length),
                    LnCardGroup(children: [
                      for (final n in attention) _AttentionRow(note: n),
                    ]),
                    const SizedBox(height: LnSpace.section),
                  ],
                  for (final group in _byDay(rest)) ...[
                    LnSectionLabel(group.$1),
                    LnCardGroup(children: [
                      for (final n in group.$2)
                        _row(context, n, previews[n.id]),
                    ]),
                    const SizedBox(height: LnSpace.section),
                  ],
                  const SizedBox(height: 120),
                ],
              );
            },
          ),
        ),
        // Fade + floating Record pill (Figma B1: pill 16 px above the tab bar).
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: Container(
              height: 120,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, 0.55, 1],
                  colors: [Color(0x00F5F3EE), Color(0xEBF5F3EE), LnColors.paper],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 16,
          child: Center(
            child: LnRecordPill(
              label: recorder.isActive
                  ? 'Recording ${formatDuration(recorder.elapsed)}'
                  : 'Record',
              onPressed: _onRecord,
            ),
          ),
        ),
      ]),
    );
  }

  static Future<(List<Recording>, Map<String, String>)> _load(
          RecordingRepository repo) async =>
      (await repo.all(), await repo.summaryPreviews());

  Widget _row(BuildContext context, Recording n, String? preview) {
    final busy = n.processingStatus.inProgress;
    return LnNoteRow(
      title: n.title,
      duration: formatDuration(n.duration),
      preview: preview ?? n.note,
      status: busy ? (n.processingProgress ?? 'Waiting to process') : null,
      progress: busy ? n.progress : null,
      onTap: () => context.pushNamed(R.note, pathParameters: {'id': n.id}),
      onLongPress: () =>
          context.pushNamed(R.noteActions, pathParameters: {'id': n.id}),
    );
  }

  static List<(String, List<Recording>)> _byDay(List<Recording> notes) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    String label(DateTime d) {
      final day = DateTime(d.year, d.month, d.day);
      final diff = today.difference(day).inDays;
      if (diff == 0) return 'Today';
      if (diff == 1) return 'Yesterday';
      const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${m[d.month - 1]} ${d.day}${d.year == now.year ? '' : ', ${d.year}'}';
    }

    final out = <(String, List<Recording>)>[];
    for (final n in notes) {
      final l = label(n.createdAt);
      if (out.isEmpty || out.last.$1 != l) out.add((l, []));
      out.last.$2.add(n);
    }
    return out;
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({required this.note});
  final Recording note;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final waiting = note.processingStatus == ProcessingStatus.waitingForNetwork;
    return LnAttentionRow(
      icon: waiting ? LnIcons.cloudOff : LnIcons.alert,
      title: note.title,
      subtitle: waiting
          ? 'Saved on phone · uploads when online'
          : (note.processingError ?? 'Processing failed · audio is safe'),
      onTap: () => context.pushNamed(R.note, pathParameters: {'id': note.id}),
      actions: [
        if (!waiting)
          LnSmallButton(label: 'Retry', onPressed: () => s.jobs.retry(note.id)),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 60),
        child: Column(children: [
          Text('No notes yet', style: LnText.noteTitle),
          const SizedBox(height: 8),
          Text('Tap Record. Long recordings are fine: 3 hours, a lecture, a whole meeting.',
              textAlign: TextAlign.center, style: LnText.meta),
        ]),
      );
}
