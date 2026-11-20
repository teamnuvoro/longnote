import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../app_services.dart';
import '../../core/analytics/analytics.dart';
import '../../core/models/recording.dart';
import '../../core/summary/summary_models.dart';
import '../../ui/widgets.dart';
import '../note/kit.dart';

/// B4 Note actions (Figma 3:300), opened by long-press on a note or the
/// "…" button: Rename, Share or export…, Copy summary, Delete note… (asks
/// again and says the audio is removed from this phone).
class NoteActionsSheet extends StatefulWidget {
  const NoteActionsSheet({super.key, required this.id});
  final String id;

  @override
  State<NoteActionsSheet> createState() => _NoteActionsSheetState();
}

class _NoteActionsSheetState extends State<NoteActionsSheet> {
  late final AppServices _s = context.read<AppServices>();
  Recording? _note;
  int _speakers = 0;
  String? _summaryText;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final n = await _s.repo.get(widget.id);
    final sp = await _s.speakers.list(widget.id);
    final sum = await _s.repo.summary(widget.id);
    String? text;
    if (sum != null && n != null) {
      try {
        final m = MeetingSummary.parse(sum.json);
        if (!m.isEmpty) text = m.toPlainText(title: n.title);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _note = n;
      _speakers = sp.length;
      _summaryText = text;
    });
  }

  Future<void> _rename() async {
    final n = _note;
    if (n == null) return;
    final name = await askForText(context, title: 'Rename', initial: n.title);
    if (name == null || name == n.title) return;
    await _s.repo.rename(n.id, name);
    _s.analytics.log(AnalyticsEvent.noteRenamed,
        recordingId: n.id, props: {'from': 'actions'});
    if (mounted) context.pop();
  }

  void _share() {
    final router = GoRouter.of(context);
    context.pop();
    router.pushNamed(R.share, pathParameters: {'id': widget.id});
  }

  Future<void> _copy() async {
    final t = _summaryText;
    if (t == null) return;
    await _s.share.copyText(t, 'summary', widget.id);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    context.pop();
    messenger?.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: LnColors.ink,
      content: Text('Summary copied',
          style: LnText.rowLabel.copyWith(color: LnColors.card)),
    ));
  }

  Future<void> _delete() async {
    final n = _note;
    if (n == null || n.status.isLive) return;
    final ok = await confirmDestructive(
      context,
      title: 'Delete this note?',
      body:
          'The audio (${spokenLength(n.duration)}), transcript and summary are removed from this phone. This can’t be undone.',
      confirmLabel: 'Delete note',
    );
    if (!ok || !mounted) return;
    final s = _s;
    context.pop();
    await s.repo.deleteByUser(n.id);
    await s.analytics.log(AnalyticsEvent.noteDeleted, recordingId: n.id);
  }

  @override
  Widget build(BuildContext context) {
    final n = _note;
    final subtitle = n == null
        ? ' '
        : [
            dayAndTime(n.createdAt, DateTime.now()),
            clockText(n.durationMs),
            if (_speakers > 1) '$_speakers speakers',
          ].join(' · ');
    return LnSheet(
      title: n?.title ?? ' ',
      subtitle: subtitle,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        LnCardGroup(dividerEndInset: 16, children: [
          LnListRow(
              icon: LnIcons.pencil,
              label: 'Rename',
              large: true,
              showChevron: false,
              onTap: n == null ? null : _rename),
          LnListRow(
              icon: LnIcons.share,
              label: 'Share or export…',
              large: true,
              showChevron: false,
              onTap: n == null ? null : _share),
          // Dimmed when there is no summary yet.
          Opacity(
            opacity: _summaryText == null && n != null ? 0.4 : 1,
            child: LnListRow(
                icon: LnIcons.copy,
                label: 'Copy summary',
                large: true,
                showChevron: false,
                onTap: _summaryText == null ? null : _copy),
          ),
        ]),
        const SizedBox(height: 12),
        LnCardGroup(children: [
          LnListRow(
              icon: LnIcons.trash,
              label: 'Delete note…',
              large: true,
              destructive: true,
              showChevron: false,
              // The note being recorded is deleted with Discard on the
              // recording screen, never from under the recorder.
              onTap: n == null || n.status.isLive ? null : _delete),
        ]),
        const SizedBox(height: 8),
      ]),
    );
  }
}
