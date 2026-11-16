import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../app/nav.dart';
import '../../app_services.dart';
import '../../core/billing/billing_service.dart';
import '../../core/models/recording.dart';
import '../../core/recording/recording_controller.dart';
import '../../core/recording/recording_repository.dart';
import '../../core/util/clock.dart';
import '../../ui/widgets.dart';
import '../note/kit.dart';

/// Notes list data, reloaded off the build path when the repository changes.
class NotesModel extends ChangeNotifier {
  NotesModel(this.repo) {
    repo.addListener(_schedule);
    _schedule();
  }
  final RecordingRepository repo;
  List<Recording>? notes;
  Map<String, String> previews = const {};
  String? _previewKey;
  bool _queued = false, _running = false, _disposed = false;

  void _schedule() {
    if (_queued) return;
    _queued = true;
    scheduleMicrotask(() async {
      _queued = false;
      if (_running) return _schedule();
      _running = true;
      try {
        final all = await repo.all();
        // Summaries only change when a note finishes: re-read previews then.
        final key = [
          for (final n in all)
            if (n.processingStatus == ProcessingStatus.done)
              '${n.id}@${n.updatedAt?.millisecondsSinceEpoch}'
        ].join(',');
        if (key != _previewKey) {
          previews = await repo.summaryPreviews();
          _previewKey = key;
        }
        if (_disposed) return;
        notes = all;
        notifyListeners();
      } finally {
        _running = false;
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    repo.removeListener(_schedule);
    super.dispose();
  }
}

/// Status line of a processing row ("Transcribing · 64%").
String processingLabel(Recording n) {
  final pct = n.progress == null ? '' : ' · ${(n.progress! * 100).round()}%';
  return switch (n.processingStatus) {
    ProcessingStatus.queued =>
      n.tries > 0 ? 'Trying again soon' : 'Waiting to start',
    ProcessingStatus.compressing => 'Preparing audio',
    ProcessingStatus.uploading => 'Uploading$pct',
    ProcessingStatus.queuedOnServer => 'In the queue',
    ProcessingStatus.transcribing => 'Transcribing$pct',
    ProcessingStatus.summarizing => 'Writing summary',
    _ => n.processingProgress ?? 'Waiting to start',
  };
}

/// B1 Notes home (Figma 3:7) and B2 empty (3:141).
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  late final AppServices _s = context.read<AppServices>();
  late final NotesModel _model = NotesModel(context.read<RecordingRepository>())
    ..addListener(_changed);
  bool _showRecovered = true;
  bool _starting = false;

  void _changed() => setState(() {});

  @override
  void dispose() {
    _model
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  Future<void> _onRecord() async {
    if (_s.recorder.isActive) {
      context.pushOnce(R.record);
      return;
    }
    if (_starting) return;
    _starting = true;
    try {
      if (!await _s.canStartRecording()) {
        if (!mounted) return;
        final ok = await context.pushOnce<bool>(R.paywall);
        if (ok != true) return;
      }
      try {
        await _s.startRecording();
      } catch (e) {
        if (!mounted) return;
        showToast(
            context,
            e.toString().contains('permission')
                ? 'Microphone is off. Turn it on in iPhone Settings › Longnote.'
                : 'Could not start recording. Please try again.');
        return;
      }
      if (mounted) context.pushOnce(R.record);
    } finally {
      _starting = false;
    }
  }

  void _open(Recording n) =>
      context.pushOnce(R.note, pathParameters: {'id': n.id});
  void _actions(Recording n) =>
      context.pushOnce(R.noteActions, pathParameters: {'id': n.id});

  @override
  Widget build(BuildContext context) {
    final all = _model.notes;
    final liveId = _s.recorder.current?.id;
    final notes = [
      for (final n in all ?? const <Recording>[])
        if (!(n.status.isLive && n.id == liveId)) n
    ];
    final attention =
        notes.where((n) => n.processingStatus.needsAttention).toList();
    final rest = notes.where((n) => !n.processingStatus.needsAttention).toList();
    final groups = _byDay(rest);
    final recovered =
        _s.recoveredAtLaunch.where((r) => r.durationMs > 0).toList();
    final empty = all != null && notes.isEmpty;
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    final slivers = <Widget>[
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
        sliver: SliverList.list(children: [
          LnLargeTitle('Notes', trailing: _TrialChip(billing: _s.billing)),
          if (!empty) ...[
            LnSearchField(
                readOnly: true, onTap: () => context.pushOnce(R.search)),
            const SizedBox(height: 20),
          ],
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
                    semanticLabel: 'Dismiss',
                    onPressed: () => setState(() => _showRecovered = false),
                  )
                ],
              ),
            ]),
            const SizedBox(height: LnSpace.section),
          ],
          if (attention.isNotEmpty) ...[
            LnSectionLabel('Waiting & needs attention', count: attention.length),
            LnCardGroup(children: [
              for (final n in attention)
                _AttentionRow(
                  note: n,
                  onTap: () => _open(n),
                  onLongPress: () => _actions(n),
                  onRetry: () => _s.jobs.retry(n.id),
                ),
            ]),
            const SizedBox(height: LnSpace.section),
          ],
        ]),
      ),
      if (empty) const SliverFillRemaining(hasScrollBody: false, child: _Empty()),
      // Day groups: one lazily built item per group card.
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
        sliver: SliverList.builder(
          itemCount: groups.length,
          itemBuilder: (context, i) {
            final g = groups[i];
            return Padding(
              padding: const EdgeInsets.only(bottom: LnSpace.section),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                LnSectionLabel(g.$1),
                LnCardGroup(children: [
                  for (final n in g.$2) _row(n, _model.previews[n.id]),
                ]),
              ]),
            );
          },
        ),
      ),
      SliverToBoxAdapter(child: SizedBox(height: 100 + bottomPad)),
    ];

    return Scaffold(
      backgroundColor: LnColors.paper,
      body: Stack(children: [
        SafeArea(
          bottom: false,
          child: CustomScrollView(slivers: slivers),
        ),
        // Fade + floating Record pill (Figma B1: 120 px fade, pill 16 px
        // above the tab bar).
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 120,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
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
          child: Center(child: _RecordButton(onPressed: _onRecord)),
        ),
      ]),
    );
  }

  Widget _row(Recording n, String? preview) {
    final busy = n.processingStatus.inProgress;
    return LnNoteRow(
      title: n.title,
      duration: clockText(n.durationMs),
      preview: preview ?? n.note,
      status: busy ? processingLabel(n) : null,
      progress: busy ? (n.progress ?? 0) : null,
      onTap: () => _open(n),
      onLongPress: () => _actions(n),
    );
  }

  static List<(String, List<Recording>)> _byDay(List<Recording> notes) {
    final now = DateTime.now();
    final out = <(String, List<Recording>)>[];
    for (final n in notes) {
      final l = dayGroupLabel(n.createdAt, now);
      if (out.isEmpty || out.last.$1 != l) out.add((l, []));
      out.last.$2.add(n);
    }
    return out;
  }
}

/// The Record pill, or "Recording · 12:04" while a recording runs in the
/// background (tap = back to the recording screen). Only this widget
/// rebuilds on recorder ticks.
class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.onPressed});
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecordingController>();
    if (!c.isActive) return LnRecordPill(onPressed: onPressed);
    final paused = c.state == CaptureState.paused;
    return LnPressable(
      onPressed: onPressed,
      semanticLabel: 'Back to recording',
      pressedOpacity: 0.8,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 18, 14),
        decoration: BoxDecoration(
          color: LnColors.night,
          borderRadius: BorderRadius.circular(LnRadius.pill),
          boxShadow: LnShadows.recordPill,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
                color: paused ? LnColors.pausedPillText : LnColors.signal,
                shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text('${paused ? 'Paused' : 'Recording'} · ${clockText(c.elapsed.inMilliseconds)}',
              style: LnText.headline.copyWith(
                  color: LnColors.card,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(width: 8),
          const LnIcon(LnIcons.chevronUp, size: 18, color: LnColors.nightText2),
        ]),
      ),
    );
  }
}

class _TrialChip extends StatelessWidget {
  const _TrialChip({required this.billing});
  final BillingService billing;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Entitlement>(
        valueListenable: billing.entitlement,
        builder: (context, e, _) {
          final end = e.trialEndsAt;
          if (e.status != EntitlementStatus.trial || end == null) {
            return const SizedBox.shrink();
          }
          final hours = end.difference(DateTime.now()).inHours;
          final days = (hours / 24).ceil();
          final label = days <= 0
              ? 'Trial · ends today'
              : 'Trial · $days ${days == 1 ? 'day' : 'days'} left';
          return LnChip(label, onTap: () => context.pushOnce(R.plan));
        },
      );
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({
    required this.note,
    required this.onTap,
    required this.onLongPress,
    required this.onRetry,
  });
  final Recording note;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final waiting = note.processingStatus == ProcessingStatus.waitingForNetwork;
    final limit = note.errorCode == 'limit_reached';
    final subtitle = waiting
        ? 'Saved on phone · uploads when online'
        : limit
            ? 'Daily limit reached · continues by itself'
            : 'Transcription failed · audio is safe';
    // Delete is in the long-press sheet only (it always asks again).
    return LnPressable(
      onPressed: onTap,
      onLongPress: onLongPress,
      pressedOpacity: 0.7,
      child: LnAttentionRow(
        icon: waiting ? LnIcons.cloudOff : LnIcons.alert,
        title: note.title,
        subtitle: subtitle,
        actions: [
          if (!waiting && !limit) LnSmallButton(label: 'Retry', onPressed: onRetry),
        ],
      ),
    );
  }
}

/// B2 (Figma 3:141): one message, one action, the consent reminder.
class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(LnSpace.page, 150, LnSpace.page, 140),
        child: Column(children: [
          SvgPicture.asset('assets/icons/empty_waveform.svg', width: 220, height: 96),
          const SizedBox(height: 14),
          SizedBox(
            width: 320,
            child: Text('Your first note is one tap away',
                textAlign: TextAlign.center,
                style: LnText.noteTitle.copyWith(fontSize: 26)),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: 315,
            child: Text(
                'Record a meeting, a class or a call. Longnote saves the audio as it goes, so a locked screen or a closed app never costs you a word.',
                textAlign: TextAlign.center,
                style: LnText.body.copyWith(
                    fontSize: 15, height: 22 / 15, color: LnColors.ink2)),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: LnColors.card,
              borderRadius: BorderRadius.circular(LnRadius.pill),
              border: Border.all(color: LnColors.line),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const LnIcon(LnIcons.lock, size: 14, color: LnColors.ink2),
              const SizedBox(width: 8),
              Text('Ask people before you record them', style: LnText.caption),
            ]),
          ),
        ]),
      );
}
