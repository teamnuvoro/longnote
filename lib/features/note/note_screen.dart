import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../app_services.dart';
import '../../core/analytics/analytics.dart';
import '../../core/models/recording.dart';
import '../../core/recording/recording_repository.dart';
import '../../ui/widgets.dart';
import 'kit.dart';
import 'note_model.dart';
import 'note_playback.dart';
import 'processing_view.dart';
import 'summary_view.dart';
import 'transcript_view.dart';

enum NoteTab { summary, transcript }

/// D1 processing · D2 summary · D3 transcript · D8 failed (Figma 7:235,
/// 7:332, 7:439, 8:923): states of one screen. `?tab=transcript&at=<ms>`
/// opens the transcript at a moment (search hits).
class NoteScreen extends StatefulWidget {
  const NoteScreen({super.key, required this.id, this.initialTab, this.atMs});
  final String id;
  final NoteTab? initialTab;
  final int? atMs;

  @override
  State<NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends State<NoteScreen> {
  late final AppServices _s = context.read<AppServices>();
  late final NoteModel _model;
  final _scroll = ScrollController();
  final _current = ValueNotifier<int>(-1);
  final _searchCtl = TextEditingController();
  NotePlayback? _player;
  late NoteTab _tab = widget.initialTab ?? NoteTab.summary;
  bool _showSpeakers = true;
  bool _searching = false;
  String _query = '';
  bool? _cloud;
  bool _popped = false;
  bool _openedAt = false;
  int? _scrollTarget;
  final _targetKey = GlobalKey();
  int _builtMin = 1 << 30, _builtMax = -1;
  final _logged = <NoteTab>{};

  @override
  void initState() {
    super.initState();
    _model = NoteModel(context.read<RecordingRepository>(), widget.id)
      ..addListener(_onData);
    _s.settings.speakerLabels().then((v) {
      if (mounted) setState(() => _showSpeakers = v);
    });
  }

  @override
  void dispose() {
    _model
      ..removeListener(_onData)
      ..dispose();
    _player?.removeListener(_onPlayback);
    if (_player != null) NotePlaybacks.release(widget.id);
    _scroll.dispose();
    _current.dispose();
    _searchCtl.dispose();
    super.dispose();
  }

  void _onData() {
    if (_model.gone) {
      _leave();
      return;
    }
    final d = _model.data!;
    final playable = d.playable;
    if (_player == null && playable.isNotEmpty && !d.note.status.isLive) {
      _player = NotePlaybacks.acquire(
          widget.id,
          () => NotePlayback(
                [
                  for (final s in playable)
                    _model.repo.storage.segmentPath(widget.id, s.fileName)
                ],
                [for (final s in playable) s.durationMs],
              ))
        ..addListener(_onPlayback);
    }
    _s.processor.modeFor(d.note).then((m) {
      final cloud = m == TranscriptionMode.cloud;
      if (mounted && cloud != _cloud) setState(() => _cloud = cloud);
    });
    if (!_openedAt && widget.atMs != null && d.lines.isNotEmpty) {
      _openedAt = true;
      _tab = NoteTab.transcript;
      _player?.seekTo(widget.atMs!, load: false);
      final i = d.turnAt(widget.atMs!);
      if (i >= 0) {
        _current.value = i;
        _scrollToTurn(i);
      }
    }
    _logView();
    setState(() {});
  }

  void _logView() {
    final d = _model.data;
    if (d == null || _logged.contains(_tab)) return;
    if (_tab == NoteTab.summary && d.summary != null) {
      _logged.add(_tab);
      _s.analytics.log(AnalyticsEvent.summaryViewed, recordingId: widget.id);
    } else if (_tab == NoteTab.transcript && d.lines.isNotEmpty) {
      _logged.add(_tab);
      _s.analytics.log(AnalyticsEvent.transcriptViewed, recordingId: widget.id);
    }
  }

  void _onPlayback() {
    final d = _model.data;
    final p = _player;
    if (d == null || p == null) return;
    if (p.playing || p.positionMs > 0) _current.value = d.turnAt(p.positionMs);
  }

  /// The note was deleted (from the actions sheet): leave this screen.
  void _leave() {
    if (_popped) return;
    _popped = true;
    final route = ModalRoute.of(context);
    if (route != null && route.isCurrent && context.canPop()) {
      context.pop();
    }
  }

  void _back() => context.canPop() ? context.pop() : context.goNamed(R.notes);

  // ---- scrolling to a turn (search hit) --------------------------------------
  void _scrollToTurn(int index, [int attempt = 0]) {
    _scrollTarget = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scrollTarget != index) return;
      final ctx = _targetKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic);
        return;
      }
      if (attempt > 8 || !_scroll.hasClients) return;
      final pos = _scroll.position;
      final mid = _builtMax < 0 ? 0 : (_builtMin + _builtMax) ~/ 2;
      final jump = (pos.pixels + (index - mid) * 90.0)
          .clamp(0.0, pos.maxScrollExtent);
      _scroll.jumpTo(jump);
      setState(() {});
      _scrollToTurn(index, attempt + 1);
    });
  }

  // ---- actions -------------------------------------------------------------------
  void _openActions() =>
      context.pushNamed(R.noteActions, pathParameters: {'id': widget.id});
  void _openShare() => context.pushNamed(R.share, pathParameters: {'id': widget.id});
  void _openAsk() => context.pushNamed(R.askChat, pathParameters: {'id': widget.id});
  void _openStyle() =>
      context.pushNamed(R.summaryStyle, pathParameters: {'id': widget.id});
  void _openSpeakers() =>
      context.pushNamed(R.speakers, pathParameters: {'id': widget.id});
  void _openPlayer() => context.pushNamed(R.player, pathParameters: {'id': widget.id});

  Future<void> _sendReport(NoteData d) async {
    final n = d.note;
    final report = [
      'Longnote error report (no audio, no transcript)',
      'Note: ${n.id}',
      'Length: ${clockText(n.durationMs)} in ${d.playable.length} parts',
      'Status: ${n.processingStatus.name}',
      'Error code: ${n.errorCode ?? '-'}',
      'Message: ${n.processingError ?? '-'}',
      'Tries: ${n.tries}',
      'Updated: ${n.updatedAt?.toIso8601String() ?? '-'}',
    ].join('\n');
    try {
      await _s.share.shareText(report, 'error_report', n);
    } catch (_) {
      if (mounted) showToast(context, 'Could not open the share sheet.');
    }
  }

  void _setTab(NoteTab t) {
    if (t == _tab) return;
    setState(() {
      _tab = t;
      _searching = false;
      _query = '';
      _searchCtl.clear();
    });
    _logView();
  }

  // ---- build -------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final d = _model.data;
    if (d == null) {
      return Scaffold(
        backgroundColor: LnColors.paper,
        appBar: LnTopBar(backLabel: 'Notes', onBack: _back),
        body: const SizedBox.shrink(),
      );
    }
    final n = d.note;
    final failed = n.processingStatus == ProcessingStatus.failed;
    final hasContent = d.lines.isNotEmpty || d.summary != null;
    final processing = !failed && !hasContent;
    final ready = !failed && hasContent;

    final slivers = <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(LnSpace.page, 8, LnSpace.page, 0),
        sliver: SliverList.list(children: [
          Text(n.title, style: LnText.detailTitle),
          const SizedBox(height: 6),
          Text(_meta(d), style: LnText.meta),
          SizedBox(height: failed ? 18 : 16),
          if (failed)
            ...failedChildren(
              d,
              canUsePhone: n.transcriptionMode != TranscriptionMode.onDevice &&
                  (_cloud == true || n.transcriptSource == 'cloud'),
              onTryAgain: () => _s.jobs.retry(widget.id),
              onTranscribeOnPhone: () => _s.transcribeOnPhoneInstead(widget.id),
              onSendReport: () => _sendReport(d),
            ),
          if (processing)
            ...processingChildren(
              d,
              cloud: n.transcriptionMode != TranscriptionMode.onDevice &&
                  (_cloud == true || n.transcriptSource == 'cloud'),
              onWhereAudioGoes: () => context.pushNamed(R.transcription),
              onBackToRecording: () => context.pushNamed(R.record),
            ),
          if (ready) ...[
            LnSegmentedControl<NoteTab>(
              segments: const {
                NoteTab.summary: 'Summary',
                NoteTab.transcript: 'Transcript'
              },
              selected: _tab,
              onChanged: _setTab,
            ),
            const SizedBox(height: 16),
            if (_tab == NoteTab.summary)
              ...summaryChildren(d,
                  onChangeStyle: _openStyle,
                  onMakeSummary: () => _s.jobs.enqueue(widget.id))
            else
              _transcriptToolbar(d),
          ],
        ]),
      ),
      if (ready && _tab == NoteTab.transcript) _transcriptSliver(d),
      SliverToBoxAdapter(
          child: SizedBox(height: 120 + MediaQuery.paddingOf(context).bottom)),
    ];

    return Scaffold(
      backgroundColor: LnColors.paper,
      appBar: LnTopBar(
        backLabel: 'Notes',
        onBack: _back,
        actions: [
          if (!failed) ...[
            LnPillButton(
              label: 'Ask',
              icon: LnIcons.sparkle,
              style: d.lines.isEmpty ? LnPillStyle.fill : LnPillStyle.ink,
              onPressed: d.lines.isEmpty ? null : _openAsk,
            ),
            LnTopBarIcon(LnIcons.share,
                semanticLabel: 'Share', onPressed: ready ? _openShare : null),
          ],
          LnTopBarIcon(LnIcons.more,
              semanticLabel: 'More', onPressed: _openActions),
        ],
      ),
      body: Stack(children: [
        Positioned.fill(
          child: CustomScrollView(controller: _scroll, slivers: slivers),
        ),
        // Bottom fade + docked mini player (Figma: 150 px fade, player 40 px up).
        if (_player != null) ...[
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 150,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00F5F3EE), Color(0xF2F5F3EE), LnColors.paper],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.paddingOf(context).bottom + 6,
            child: ListenableBuilder(
              listenable: _player!,
              builder: (context, _) {
                final p = _player!;
                return LnMiniPlayer(
                  playing: p.playing,
                  position: Duration(milliseconds: p.positionMs),
                  duration: Duration(milliseconds: p.totalMs),
                  speed: p.speed,
                  onPlayPause: p.toggle,
                  onSpeed: p.cycleSpeed,
                  onExpand: _openPlayer,
                  onSeekFraction: (f) => p.seekTo((f * p.totalMs).round()),
                );
              },
            ),
          ),
        ],
      ]),
    );
  }

  String _meta(NoteData d) {
    final n = d.note;
    final parts = <String>[
      dayAndTime(n.createdAt, DateTime.now()),
      clockText(n.durationMs),
      if (d.speakers.length > 1) '${d.speakers.length} speakers',
    ];
    final code = n.language == null || n.language == 'auto'
        ? d.detectedLanguage
        : n.language;
    if (code != null) parts.add(languageName(code));
    return parts.join(' · ');
  }

  Widget _transcriptToolbar(NoteData d) {
    if (_searching) {
      final count = _matches(d).length;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: LnSearchField(
                controller: _searchCtl,
                autofocus: true,
                hint: 'Search this transcript',
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
            const SizedBox(width: 12),
            LnPressable(
              onPressed: () => setState(() {
                _searching = false;
                _query = '';
                _searchCtl.clear();
              }),
              child: Text('Cancel',
                  style: LnText.headline.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      fontVariations: const [FontVariation('wght', 500)])),
            ),
          ]),
          if (_query.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(count == 1 ? '1 line' : '$count lines', style: LnText.sectionLabel),
          ],
        ]),
      );
    }
    final canToggle = d.hasSpeakers;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        LnToggle(
          small: true,
          value: canToggle && _showSpeakers,
          semanticLabel: 'Speakers',
          onChanged: canToggle ? (v) => setState(() => _showSpeakers = v) : null,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text('Speakers',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: LnText.segment.copyWith(
                  color: canToggle ? LnColors.ink : LnColors.ink3)),
        ),
        if (canToggle) ...[
          LnPillButton(label: 'Edit names', icon: LnIcons.pencil, onPressed: _openSpeakers),
          const SizedBox(width: 8),
        ],
        LnIconButton(
          icon: LnIcons.search,
          size: 32,
          iconSize: 15,
          background: LnColors.card,
          semanticLabel: 'Search in transcript',
          onPressed: () => setState(() => _searching = true),
        ),
      ]),
    );
  }

  Set<int> _matches(NoteData d) {
    final q = _query.toLowerCase();
    if (q.isEmpty) return const {};
    return {
      for (var i = 0; i < d.lines.length; i++)
        if (d.lines[i].text.toLowerCase().contains(q)) i
    };
  }

  Widget _transcriptSliver(NoteData d) {
    if (d.lines.isEmpty) {
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
        sliver: SliverToBoxAdapter(
          child: Text(
              d.note.processingStatus.inProgress
                  ? 'The transcript is still being written.'
                  : 'No speech was found in this recording.',
              style: LnText.bullet.copyWith(color: LnColors.ink2)),
        ),
      );
    }
    final filtered = _searching && _query.isNotEmpty;
    final entries =
        transcriptEntries(d, filter: filtered ? _matches(d) : null);
    final showSpeakers = _showSpeakers && d.hasSpeakers;
    _builtMin = 1 << 30;
    _builtMax = -1;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
      sliver: SliverList.builder(
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final e = entries[i];
          if (e.gap != null) return GapMarker(gap: e.gap!);
          final idx = e.index;
          if (idx < _builtMin) _builtMin = idx;
          if (idx > _builtMax) _builtMax = idx;
          final line = d.lines[idx];
          return ValueListenableBuilder<int>(
            key: idx == _scrollTarget ? _targetKey : null,
            valueListenable: _current,
            builder: (context, cur, _) => TurnRow(
              line: line,
              name: d.nameOf(line.speaker),
              colorIndex: d.colorOf(line.speaker),
              showSpeaker: showSpeakers,
              highlighted: cur == idx,
              query: filtered ? _query : null,
              onTap: () {
                _current.value = idx;
                _player?.playFrom(line.startMs);
              },
            ),
          );
        },
      ),
    );
  }
}
