import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/util/coalescing_runner.dart';
import '../../app/routes.dart';
import '../../app/nav.dart';
import '../../app_services.dart';
import '../../core/models/recording.dart';
import '../../core/recording/recording_repository.dart';
import '../../ui/widgets.dart';
import '../common/external.dart';
import '../common/widgets.dart';
import '../common/note_ready_ask.dart';
import 'import_controller.dart';
import 'import_widgets.dart';

/// F1 Import (Figma 9:684) and, while a file is being copied, F3 (9:889):
/// Files, Photos (the sound of a video), Voice Memos (how-to), the copies in
/// progress and recent imports.
///
/// Files shared INTO the app from other apps (share sheet / "Open in") are
/// not wired yet: TODO needs a Share Extension target or scene URL handling
/// in Xcode (see docs/APP-ARCHITECTURE.md, "Import").
class ImportScreen extends StatelessWidget {
  const ImportScreen({super.key});

  @override
  Widget build(BuildContext context) => const LnScaffold(
        backgroundColor: LnColors.paper,
        body: SafeArea(bottom: false, child: ImportBody(tabRoot: true)),
      );
}

/// Shared body of F1/F3 (the tab) and the pushed progress screen.
class ImportBody extends StatefulWidget {
  const ImportBody({super.key, this.tabRoot = true, this.onlyJob});
  final bool tabRoot;

  /// Progress screen: show only this job (note id).
  final String? onlyJob;

  @override
  State<ImportBody> createState() => _ImportBodyState();
}

class _ImportBodyState extends State<ImportBody> {
  late final ImportController _c;
  late final RecordingRepository _repo;
  List<Recording> _recent = const [];

  @override
  void initState() {
    super.initState();
    _c = ImportController.of(context.read<AppServices>());
    _repo = context.read<RecordingRepository>();
    _c.addListener(_changed);
    _repo.addListener(_recentRunner.request);
    _s = context.read<AppServices>()..noteReadyAskDue.addListener(_maybeAsk);
    WidgetsBinding.instance.addPostFrameCallback((_) => _recentRunner.request());
  }

  late final AppServices _s;

  /// The first imported note was queued: ask about "note ready" alerts once
  /// (only while this tab is what the user sees).
  void _maybeAsk() {
    if (!_s.noteReadyAskDue.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if ((route?.isCurrent ?? false) && TickerMode.valuesOf(context).enabled) {
        askNoteReadyOnce(context);
      }
    });
  }

  @override
  void dispose() {
    _s.noteReadyAskDue.removeListener(_maybeAsk);
    _c.removeListener(_changed);
    _repo.removeListener(_recentRunner.request);
    _recentRunner.close();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _recentKey = '';

  /// One reload at a time, however often the repository changes.
  late final CoalescingRunner _recentRunner = CoalescingRunner(_loadRecent);

  /// Reloads on repository changes, but rebuilds only when the recent
  /// imports changed (uploads elsewhere notify many times a minute).
  Future<void> _loadRecent() async {
    final all = await _repo.all();
    final r = [
      for (final n in all)
        if (n.source == 'imported') n
    ].take(5).toList();
    final key = [
      for (final n in r)
        '${n.id}|${n.title}|${n.processingStatus.name}|${n.progress}|${n.processingProgress}'
    ].join(',');
    if (!mounted || key == _recentKey) return;
    _recentKey = key;
    setState(() => _recent = r);
  }

  Future<void> _pick({bool video = false}) async {
    // Import is Pro only: the paywall first without a plan.
    if (!await importPaywallPassed(context, _c)) return;
    try {
      final m = await _c.pick(video: video);
      if (m == null || !mounted) return;
      await context.pushOnce(R.importDetails);
    } catch (_) {
      if (mounted) {
        showNote(context, 'Could not open the picker. Try again.');
      }
    }
  }

  void _voiceMemos() {
    showLnSheet<void>(context, builder: (ctx) => _VoiceMemosHelp(onFiles: () {
          Navigator.of(ctx).pop();
          _pick();
        }));
  }

  @override
  Widget build(BuildContext context) {
    final jobs = widget.onlyJob == null
        ? _c.jobs
        : _c.jobs.where((j) => j.id == widget.onlyJob).toList();
    final copying = jobs.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
      children: [
        if (widget.tabRoot) const LnLargeTitle('Import'),
        if (widget.onlyJob != null && jobs.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text('Copy finished. The note is in Recent imports.',
                style: LnText.meta),
          ),
        for (final j in jobs) ...[
          ImportProgressCard(job: j, onCancel: () => _c.cancel(j)),
          const SizedBox(height: 10),
        ],
        if (!copying && widget.onlyJob == null) ...[
          LnPressable(
            onPressed: _pick,
            pressedOpacity: 0.7,
            semanticLabel: 'Bring in a recording',
            child: DashedBorder(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
                decoration: BoxDecoration(
                    color: LnColors.card,
                    borderRadius: BorderRadius.circular(20)),
                child: Column(children: [
                  const LnIconTile(LnIcons.tabImport,
                      size: 56, iconSize: 26, radius: 16),
                  const SizedBox(height: 12),
                  Text('Bring in a recording', style: LnText.noteTitle),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: 270,
                    child: Text(
                        'Audio or video, any length. We keep a copy on this phone.',
                        textAlign: TextAlign.center,
                        style: LnText.preview),
                  ),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _SourceCard(
            onFiles: _pick,
            onPhotos: () => _pick(video: true),
            onVoiceMemos: _voiceMemos,
          ),
          const SizedBox(height: 12),
          Text('Works with MP3, M4A, WAV, AAC, MP4 and MOV.',
              textAlign: TextAlign.center,
              style: LnText.meta.copyWith(color: LnColors.ink3)),
        ],
        RecentImports(notes: _recent, topGap: copying ? 4 : 18),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard(
      {required this.onFiles, required this.onPhotos, required this.onVoiceMemos});
  final VoidCallback onFiles;
  final VoidCallback onPhotos;
  final VoidCallback onVoiceMemos;

  @override
  Widget build(BuildContext context) => LnCardGroup(
        dividerInset: 62,
        dividerEndInset: 0,
        children: [
          _SourceRow(LnIcons.folder, 'Files', 'iCloud Drive, Google Drive, Dropbox', onFiles),
          _SourceRow(LnIcons.image, 'Photos', 'Use the sound from a video', onPhotos),
          _SourceRow(LnIcons.mic, 'Voice Memos', 'Save it to Files, then pick it here', onVoiceMemos),
        ],
      );
}

class _SourceRow extends StatelessWidget {
  const _SourceRow(this.icon, this.title, this.sub, this.onTap);
  final LnIcons icon;
  final String title;
  final String sub;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        pressedOpacity: 0.6,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            LnIconTile(icon),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: LnText.rowTitleSmall),
                const SizedBox(height: 2),
                Text(sub, style: LnText.meta),
              ]),
            ),
            const LnIcon(LnIcons.chevronRight, size: 16, color: LnColors.ink3),
          ]),
        ),
      );
}

class _VoiceMemosHelp extends StatelessWidget {
  const _VoiceMemosHelp({required this.onFiles});
  final VoidCallback onFiles;
  @override
  Widget build(BuildContext context) {
    Widget step(int n, String t) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                  color: LnColors.fill, shape: BoxShape.circle),
              child: Text('$n', style: LnText.smallButton.copyWith(fontSize: 12)),
            ),
            const SizedBox(width: 10),
            Expanded(
                child: Text(t, style: LnText.preview.copyWith(color: LnColors.ink))),
          ]),
        );
    return LnPlainSheet(
      title: 'From Voice Memos',
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        LnCard(
          child: Column(children: [
            step(1, 'In Voice Memos, tap the recording, then ••• (More).'),
            step(2, 'Tap Share → Save to Files, and pick a folder.'),
            step(3, 'Come back here and choose it from Files.'),
          ]),
        ),
        const SizedBox(height: 16),
        LnPrimaryButton(label: 'Choose from Files', onPressed: onFiles),
      ]),
    );
  }
}

/// True when the user may import now; otherwise shows the paywall
/// (placement `import`) and returns whether they now have access.
Future<bool> importPaywallPassed(BuildContext context, ImportController c) async {
  if (await c.canImport()) return true;
  if (!context.mounted) return false;
  final ok = await context.pushOnce<bool>(R.paywall,
      queryParameters: {'from': 'import'});
  return ok == true;
}
