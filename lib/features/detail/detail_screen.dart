import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/analytics/analytics.dart';
import '../../core/export/text_format.dart';
import '../../core/models/recording.dart';
import '../../core/recording/recording_repository.dart';
import '../../core/summary/summary_models.dart';
import '../../core/util/clock.dart';
import '../home/home_screen.dart' show statusChips;
import 'playback_controller.dart';

class _DetailData {
  _DetailData(this.r, this.segments, this.lines, this.summary, this.engine,
      this.note, this.gaps);
  final Recording r;
  final List<AudioSegment> segments;
  final List<TranscriptLine> lines;
  final MeetingSummary? summary;
  final String? engine;
  final String? note;
  final List<RecordingGap> gaps;
}

/// Summary | Transcript | Audio, plus rename/share/export and retry.
class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.recordingId});
  final String recordingId;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  late RecordingRepository _repo;
  _DetailData? _data;
  PlaybackController? _player;
  final _viewed = <int>{};

  AppServices get _s => context.read<AppServices>();

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) _logView(_tabs.index);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _repo = context.read<RecordingRepository>();
    _repo.removeListener(_load);
    _repo.addListener(_load);
    if (_data == null) _load();
  }

  @override
  void dispose() {
    _repo.removeListener(_load);
    _tabs.dispose();
    _player?.dispose();
    super.dispose();
  }

  void _logView(int tab) {
    final d = _data;
    if (d == null || !_viewed.add(tab)) return;
    if (tab == 0 && d.summary != null) {
      _s.analytics.log(AnalyticsEvent.summaryViewed, recordingId: d.r.id);
    } else if (tab == 1 && d.lines.isNotEmpty) {
      _s.analytics.log(AnalyticsEvent.transcriptViewed, recordingId: d.r.id);
    }
    if (tab == 0 && d.summary == null) _viewed.remove(0);
    if (tab == 1 && d.lines.isEmpty) _viewed.remove(1);
  }

  Future<void> _load() async {
    final r = await _repo.get(widget.recordingId);
    if (r == null) {
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
    final segs = await _repo.segments(r.id);
    final lines = await _repo.transcript(r.id);
    final sum = await _repo.summary(r.id);
    final gaps = await _repo.gaps(r.id);
    MeetingSummary? parsed;
    if (sum != null) {
      try {
        parsed = MeetingSummary.parse(sum.json);
      } catch (_) {}
    }
    if (!mounted) return;
    final playable = segs.where((s) => s.dataBytes > 0).toList();
    if (_player == null && playable.isNotEmpty && !r.status.isLive) {
      _player = PlaybackController(
        [for (final s in playable) _repo.storage.segmentPath(r.id, s.fileName)],
        [for (final s in playable) s.durationMs],
      );
    }
    setState(() => _data =
        _DetailData(r, segs, lines, parsed, sum?.engine, sum?.note, gaps));
    _logView(_tabs.index);
  }

  Future<void> _rename() async {
    final d = _data!;
    final ctl = TextEditingController(text: d.r.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await _repo.rename(d.r.id, name.trim());
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this recording?'),
        content: const Text('The audio, transcript and summary will be removed from this phone. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true && mounted) {
      _player?.dispose();
      _player = null;
      final nav = Navigator.of(context);
      await _repo.deleteByUser(widget.recordingId);
      nav.pop();
    }
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _menu(String action, Rect origin) async {
    final d = _data!;
    final share = _s.share;
    final summaryText = d.summary?.toPlainText(title: d.r.title);
    final transcriptText = transcriptToText(d.lines);
    try {
      switch (action) {
        case 'rename':
          await _rename();
        case 'copy_summary':
          if (summaryText == null) return _toast('No summary yet.');
          await share.copyText(summaryText, 'summary', d.r.id);
          _toast('Summary copied');
        case 'copy_transcript':
          if (d.lines.isEmpty) return _toast('No transcript yet.');
          await share.copyText(transcriptText, 'transcript', d.r.id);
          _toast('Transcript copied');
        case 'share_summary':
          if (summaryText == null) return _toast('No summary yet.');
          await share.shareText(summaryText, 'summary', d.r, origin: origin);
        case 'share_transcript':
          if (d.lines.isEmpty) return _toast('No transcript yet.');
          await share.shareText(transcriptText, 'transcript', d.r, origin: origin);
        case 'pdf':
          await share.sharePdf(d.r, summary: d.summary, note: d.note, origin: origin);
        case 'audio':
          _toast('Preparing audio...');
          await share.shareAudio(d.r, origin: origin);
        case 'resummarize':
          await _s.jobs.enqueue(d.r.id);
          _toast('Making a new summary...');
        case 'delete':
          await _delete();
      }
    } catch (e) {
      _toast('Something went wrong: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final r = d.r;
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _rename,
          child: Text(r.title, overflow: TextOverflow.ellipsis),
        ),
        actions: [
          Builder(builder: (bctx) {
            return PopupMenuButton<String>(
              tooltip: 'Share and more',
              icon: const Icon(Icons.ios_share),
              onSelected: (v) {
                final box = bctx.findRenderObject() as RenderBox?;
                final origin = box == null
                    ? Rect.zero
                    : box.localToGlobal(Offset.zero) & box.size;
                _menu(v, origin);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'copy_summary', child: Text('Copy summary')),
                PopupMenuItem(value: 'copy_transcript', child: Text('Copy transcript')),
                PopupMenuItem(value: 'share_summary', child: Text('Share summary')),
                PopupMenuItem(value: 'share_transcript', child: Text('Share transcript')),
                PopupMenuItem(value: 'pdf', child: Text('Export PDF')),
                PopupMenuItem(value: 'audio', child: Text('Share original audio')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'resummarize', child: Text('Make summary again')),
                PopupMenuItem(value: 'delete', child: Text('Delete recording')),
              ],
            );
          }),
        ],
        bottom: TabBar(controller: _tabs, tabs: const [
          Tab(text: 'Summary'),
          Tab(text: 'Transcript'),
          Tab(text: 'Audio'),
        ]),
      ),
      body: Column(
        children: [
          _StatusHeader(data: d, onRetry: () => _s.jobs.retry(r.id)),
          Expanded(
            child: TabBarView(controller: _tabs, children: [
              _SummaryTab(data: d),
              _TranscriptTab(
                data: d,
                onTapLine: (ms) {
                  _player?.playFrom(ms);
                  _tabs.animateTo(2);
                },
              ),
              _AudioTab(data: d, player: _player),
            ]),
          ),
        ],
      ),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.data, required this.onRetry});
  final _DetailData data;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final r = data.r;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final d = r.createdAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('${d.day}/${d.month}/${d.year}  ·  ${formatMinutes(r.duration)}', style: t.bodyMedium),
            ...statusChips(context, r),
          ]),
          if (r.note != null) ...[
            const SizedBox(height: 6),
            Text(r.note!, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
          if (r.processingStatus == ProcessingStatus.failed) ...[
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              color: cs.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Processing did not finish. Your audio is safe and still playable.',
                      style: t.bodyMedium?.copyWith(color: cs.onErrorContainer)),
                  if (r.processingError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(r.processingError!,
                          maxLines: 3, overflow: TextOverflow.ellipsis,
                          style: t.bodySmall?.copyWith(color: cs.onErrorContainer)),
                    ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry processing')),
                ]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryTab extends StatelessWidget {
  const _SummaryTab({required this.data});
  final _DetailData data;

  static String engineLabel(String? e) => switch (e) {
        'apple' => 'Apple Intelligence, on this phone',
        'cloud' => 'Cloud summary',
        'local' => 'Basic offline summary (picks sentences from the transcript)',
        _ => 'Unknown',
      };

  @override
  Widget build(BuildContext context) {
    final s = data.summary;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    if (s == null) {
      return _Waiting(r: data.r, what: 'summary');
    }
    Widget section(String title, List<Widget> items) => items.isEmpty
        ? const SizedBox.shrink()
        : Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                ...items,
              ]),
            ),
          );
    Widget bullet(String text, {String? extra}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('•  '),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SelectableText(text, style: t.bodyLarge),
                if (extra != null)
                  Text(extra, style: t.bodySmall?.copyWith(color: cs.primary)),
              ]),
            ),
          ]),
        );

    return ListView(
      padding: const EdgeInsets.only(bottom: 32, top: 4),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text('Made by: ${engineLabel(data.engine)}',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ),
        if (data.note != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(data.note!, style: t.bodySmall?.copyWith(color: cs.tertiary)),
          ),
        if (s.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Nothing to summarize. The transcript is empty or very short.'),
          ),
        section('Key points', [for (final k in s.keyPoints) bullet(k)]),
        section('Decisions', [for (final k in s.decisions) bullet(k)]),
        section('Action items', [
          for (final a in s.actionItems)
            bullet(a.task,
                extra: [
                  if (a.owner != null) 'Owner: ${a.owner}',
                  if (a.due != null) 'Due: ${a.due}',
                ].join('  ·  ').ifEmptyNull()),
        ]),
        section('Numbers and dates', [for (final k in s.numbersAndDates) bullet(k)]),
        section('Open questions', [for (final k in s.openQuestions) bullet(k)]),
      ],
    );
  }
}

extension on String {
  String? ifEmptyNull() => isEmpty ? null : this;
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.r, required this.what});
  final Recording r;
  final String what;

  @override
  Widget build(BuildContext context) {
    final busy = r.processingStatus == ProcessingStatus.queued ||
        r.processingStatus == ProcessingStatus.transcribing ||
        r.processingStatus == ProcessingStatus.summarizing;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (busy) const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            busy
                ? (r.processingProgress ?? 'Waiting to start...')
                : r.processingStatus == ProcessingStatus.failed
                    ? 'No $what yet. Tap "Retry processing" above.'
                    : r.durationMs == 0
                        ? 'No audio was saved, so there is no $what.'
                        : 'No $what yet.',
            textAlign: TextAlign.center,
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'This runs on your phone. Keep the app open for faster results; it continues next time you open it if interrupted.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ),
        ]),
      ),
    );
  }
}

class _TranscriptTab extends StatelessWidget {
  const _TranscriptTab({required this.data, required this.onTapLine});
  final _DetailData data;
  final void Function(int ms) onTapLine;

  @override
  Widget build(BuildContext context) {
    if (data.lines.isEmpty) return _Waiting(r: data.r, what: 'transcript');
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      itemCount: data.lines.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Made on this phone. Speaker names are not available yet. Tap a line to play from there.',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          );
        }
        final l = data.lines[i - 1];
        return InkWell(
          onTap: () => onTapLine(l.startMs),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 64,
                child: Text(formatTimestamp(l.startMs),
                    style: t.bodySmall?.copyWith(color: cs.primary)),
              ),
              Expanded(child: Text(l.text, style: t.bodyLarge)),
            ]),
          ),
        );
      },
    );
  }
}

class _AudioTab extends StatelessWidget {
  const _AudioTab({required this.data, required this.player});
  final _DetailData data;
  final PlaybackController? player;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = player;
    if (p == null) {
      return const Center(child: Text('No audio was saved for this recording.'));
    }
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final pos = p.positionMs.clamp(0, p.totalMs);
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (p.error != null)
              Text(p.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            Slider(
              value: p.totalMs == 0 ? 0 : pos.toDouble(),
              max: p.totalMs == 0 ? 1 : p.totalMs.toDouble(),
              onChanged: (v) => p.seekTo(v.round()),
              semanticFormatterCallback: (v) => formatTimestamp(v.round()),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(formatTimestamp(pos)),
              Text(formatTimestamp(p.totalMs)),
            ]),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                  tooltip: 'Back 10 seconds',
                  iconSize: 36,
                  onPressed: () => p.skip(-10000),
                  icon: const Icon(Icons.replay_10)),
              const SizedBox(width: 16),
              IconButton.filled(
                  tooltip: p.playing ? 'Pause' : 'Play',
                  iconSize: 48,
                  onPressed: p.toggle,
                  icon: Icon(p.playing ? Icons.pause : Icons.play_arrow)),
              const SizedBox(width: 16),
              IconButton(
                  tooltip: 'Forward 10 seconds',
                  iconSize: 36,
                  onPressed: () => p.skip(10000),
                  icon: const Icon(Icons.forward_10)),
            ]),
            const SizedBox(height: 24),
            Text('The original audio is kept on this phone, exactly as recorded.',
                style: t.bodySmall),
            if (data.gaps.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Gaps', style: t.titleSmall),
              for (final g in data.gaps)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'At ${formatTimestamp(g.atMs)}: not recorded for '
                    '${g.endedAt == null ? 'an unknown time' : formatMinutes(g.endedAt!.difference(g.startedAt))} '
                    '(phone call or another app used the microphone).',
                    style: t.bodySmall,
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}
