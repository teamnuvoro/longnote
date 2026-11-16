import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/models/recording.dart';
import '../../core/summary/summary_models.dart';
import '../../ui/widgets.dart';
import 'kit.dart';

/// D5 Share & export (Figma 8:288): PDF, summary text, transcript text,
/// audio (M4A or WAV), Copy summary, and "Include speaker names". Each row
/// opens the normal iOS share sheet through [ShareService].
class ShareSheet extends StatefulWidget {
  const ShareSheet({super.key, required this.id});
  final String id;

  @override
  State<ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<ShareSheet> {
  late final AppServices _s = context.read<AppServices>();
  Recording? _note;
  MeetingSummary? _summary;
  String? _summaryNote;
  Map<String, String> _names = const {};
  bool _hasTranscript = false;
  bool _includeNames = true;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final note = await _s.repo.get(widget.id);
    final sum = await _s.repo.summary(widget.id);
    final names = await _s.speakers.names(widget.id);
    final lines = await _s.repo.transcript(widget.id);
    MeetingSummary? parsed;
    if (sum != null) {
      try {
        parsed = MeetingSummary.parse(sum.json);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _note = note;
      _summary = parsed;
      _summaryNote = sum?.note;
      _names = names;
      _hasTranscript = lines.isNotEmpty;
    });
  }

  Rect? _origin() {
    final box = context.findRenderObject() as RenderBox?;
    return box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  String? get _summaryText {
    final s = _summary;
    final n = _note;
    if (s == null || n == null || s.isEmpty) return null;
    return s.toPlainText(title: n.title);
  }

  Future<void> _run(String kind, Future<void> Function(Recording n) job) async {
    final n = _note;
    if (n == null || _busy != null) return;
    setState(() => _busy = kind);
    try {
      await job(n);
    } catch (_) {
      if (mounted) showToast(context, 'Could not share this. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _pdf() => _run('pdf', (n) => _s.share.sharePdf(n,
      summary: _summary,
      note: _summaryNote,
      origin: _origin(),
      speakerNames: _includeNames ? _names : null));

  Future<void> _summaryShare() async {
    final t = _summaryText;
    if (t == null) return showToast(context, 'There is no summary yet.');
    await _run('summary', (n) => _s.share.shareText(t, 'summary', n, origin: _origin()));
  }

  Future<void> _transcriptShare() async {
    if (!_hasTranscript) return showToast(context, 'There is no transcript yet.');
    await _run('transcript', (n) async {
      final lines = await _s.repo.transcript(n.id);
      final text = _s.share.transcriptText(lines,
          names: _includeNames ? {for (final e in _names.entries) e.key: e.value} : null);
      await _s.share.shareText(text, 'transcript', n, origin: _origin());
    });
  }

  Future<void> _audio() async {
    final n = _note;
    if (n == null) return;
    if (n.source == 'imported') {
      // The original file is shared as is; no format to choose.
      await _run('audio', (n) => _s.share.shareAudio(n, origin: _origin()));
      return;
    }
    final choice = await showLnSheet<String>(
      context,
      builder: (c) => LnSheet(
        title: 'Audio file',
        subtitle: clockText(n.durationMs),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          LnCardGroup.settings(children: [
            LnListRow(
              icon: LnIcons.share,
              label: 'M4A · smaller',
              value: '≈ ${_mb(n.durationMs, 15)} MB',
              large: true,
              onTap: () => Navigator.of(c).pop('m4a'),
            ),
            LnListRow(
              icon: LnIcons.share,
              label: 'WAV · original quality',
              value: '≈ ${_mb(n.durationMs, 115)} MB',
              large: true,
              onTap: () => Navigator.of(c).pop('wav'),
            ),
          ]),
        ]),
      ),
    );
    if (choice == null) return;
    await _run('audio', (n) => choice == 'm4a'
        ? _s.share.shareAudioM4a(n, origin: _origin())
        : _s.share.shareAudio(n, origin: _origin()));
  }

  static int _mb(int ms, int perHour) =>
      (ms / 3600000 * perHour).ceil().clamp(1, 1 << 20);

  Future<void> _copy() async {
    final t = _summaryText;
    final n = _note;
    if (t == null || n == null) return showToast(context, 'There is no summary yet.');
    await _s.share.copyText(t, 'summary', n.id);
    if (mounted) showToast(context, 'Summary copied');
  }

  @override
  Widget build(BuildContext context) {
    final n = _note;
    final hasSummary = _summaryText != null;
    return LnSheet(
      scrollable: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(children: [
              Expanded(
                  child: Text('Share',
                      style: LnText.noteTitle.copyWith(fontSize: 24))),
              LnSheetAction('Done', emphasized: true, onPressed: () => context.pop()),
            ]),
          ),
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: LnColors.card,
              borderRadius: BorderRadius.circular(LnRadius.card),
              border: Border.all(color: LnColors.line),
            ),
            child: Column(children: [
              _ShareRow(
                icon: NoteIcons.shareFile,
                title: 'PDF',
                subtitle: 'Summary and full transcript, ready to send',
                busy: _busy == 'pdf',
                onTap: n == null ? null : _pdf,
              ),
              const _Divider(),
              _ShareRow(
                icon: NoteIcons.shareList,
                title: 'Summary',
                subtitle: 'As text: decisions and action items',
                busy: _busy == 'summary',
                onTap: hasSummary ? _summaryShare : null,
              ),
              const _Divider(),
              _ShareRow(
                icon: NoteIcons.shareQuote,
                title: 'Transcript',
                subtitle: _includeNames
                    ? 'As text, with speaker names and times'
                    : 'As text, with times',
                busy: _busy == 'transcript',
                onTap: _hasTranscript ? _transcriptShare : null,
              ),
              const _Divider(),
              _ShareRow(
                icon: NoteIcons.shareAudio,
                title: 'Audio file',
                subtitle: n == null
                    ? 'M4A or WAV'
                    : 'M4A · ${clockText(n.durationMs)} · about ${_mb(n.durationMs, 15)} MB',
                busy: _busy == 'audio',
                onTap: n == null || n.durationMs == 0 ? null : _audio,
              ),
            ]),
          ),
          const SizedBox(height: 12),
          LnPressable(
            onPressed: hasSummary ? _copy : null,
            semanticLabel: 'Copy summary',
            child: Container(
              height: 50,
              decoration: BoxDecoration(
                color: LnColors.card,
                borderRadius: BorderRadius.circular(LnRadius.button),
                border: Border.all(color: LnColors.line),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const LnIcon(LnIcons.copy, size: 17),
                const SizedBox(width: 8),
                Text('Copy summary', style: LnText.rowTitleSmall),
              ]),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(children: [
              Expanded(
                  child: Text('Include speaker names',
                      style: LnText.segment.copyWith(color: LnColors.ink2))),
              LnToggle(
                small: true,
                value: _includeNames,
                semanticLabel: 'Include speaker names',
                onChanged: (v) => setState(() => _includeNames = v),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.only(left: 60), child: LnHairline());
}

class _ShareRow extends StatelessWidget {
  const _ShareRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.busy = false,
  });
  final NoteIcons icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        pressedOpacity: 0.7,
        semanticLabel: title,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            IconTile(child: NoteIcon(icon, size: 18)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: LnText.rowTitleSmall),
                const SizedBox(height: 2),
                Text(busy ? 'Preparing…' : subtitle, style: LnText.meta),
              ]),
            ),
            const SizedBox(width: 8),
            const LnIcon(LnIcons.chevronRight, size: 18, color: LnColors.ink3),
          ]),
        ),
      );
}
