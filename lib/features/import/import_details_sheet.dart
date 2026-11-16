import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/models/recording.dart';
import '../../core/notes/languages.dart';
import '../../core/summary/summary_style.dart';
import '../../core/util/clock.dart';
import '../../ui/widgets.dart';
import '../common/dates.dart';
import '../common/widgets.dart';
import '../settings/audio_language_screen.dart';
import 'import_controller.dart';

/// F2 Import — before we start (Figma 9:781): the picked file, its name,
/// language and summary style, then "Import and transcribe" (copy with
/// progress on the Import tab, then the same pipeline as a recording).
class ImportDetailsSheet extends StatefulWidget {
  const ImportDetailsSheet({super.key});
  @override
  State<ImportDetailsSheet> createState() => _ImportDetailsSheetState();
}

class _ImportDetailsSheetState extends State<ImportDetailsSheet> {
  final _name = TextEditingController();
  late final ImportController _c;
  PickedMedia? _m;
  String _language = 'auto';
  SummaryStyle _style = SummaryStyle.meeting;
  TranscriptionMode _mode = TranscriptionMode.cloud;
  bool _cloudAvailable = true;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppServices>();
    _c = ImportController.of(s);
    _c.addListener(_changed);
    _m = _c.pending;
    _name.text = _m?.suggestedTitle ?? '';
    _cloudAvailable = s.cloud != null || s.api != null;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final lang = await s.settings.audioLanguage();
      final style = await s.settings.defaultStyle();
      final mode = await s.settings.transcriptionMode();
      if (mounted) {
        setState(() {
          _language = lang;
          _style = style;
          _mode = mode;
        });
      }
    });
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _name.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _pickLanguage() async {
    final v = await Navigator.of(context, rootNavigator: true).push<String>(
      CupertinoPageRoute(
        builder: (_) => AudioLanguageScreen(
            initial: _language, onPicked: (_) {}, backLabel: 'Back'),
      ),
    );
    if (v != null && mounted) setState(() => _language = v);
  }

  Future<void> _pickStyle() async {
    final v = await showLnSheet<SummaryStyle>(context,
        builder: (_) => _StylePicker(current: _style));
    if (v != null && mounted) setState(() => _style = v);
  }

  /// On-device mode cannot read imported files yet (whisper takes our WAV
  /// parts only): imports go to the cloud, and the button says so.
  bool get _needsCloud => _mode == TranscriptionMode.onDevice;

  void _start() {
    final m = _m;
    if (m == null) return;
    unawaited(_c.start(m,
        title: _name.text,
        language: _language,
        summaryStyle: _style.id,
        forceCloud: _needsCloud));
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    if (m == null) {
      return LnPlainSheet(
        title: 'Import',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('No file was chosen. Pick one from Files or Photos.',
              style: LnText.meta),
          const SizedBox(height: 16),
          LnSecondaryButton(
              label: 'Close', onPressed: () => Navigator.of(context).maybePop()),
        ]),
      );
    }
    final length = m.durationMs != null
        ? formatDuration(Duration(milliseconds: m.durationMs!))
        : (m.probed ? 'length unknown' : 'reading…');
    final blocked = _needsCloud && !_cloudAvailable;
    return LnPlainSheet(
      scrollable: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        LnCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            const LnIconTile(LnIcons.document, size: 40, iconSize: 20, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: LnText.rowTitleSmall),
                const SizedBox(height: 2),
                Text('$length · ${megabytes(m.bytes)}',
                    style: LnText.monoSmall.copyWith(color: LnColors.ink2)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        Text('Name', style: LnText.caption),
        const SizedBox(height: 6),
        LnTextField(controller: _name, hint: m.suggestedTitle, maxLength: 120),
        const SizedBox(height: 14),
        LnCardGroup(
          dividerInset: 48,
          dividerEndInset: 0,
          children: [
            _OptionRow(
                icon: LnIcons.globe,
                label: 'Language',
                value: audioLanguageFor(_language).name,
                onTap: _pickLanguage),
            _OptionRow(
                icon: LnIcons.template,
                label: 'Summary style',
                value: _style.label,
                onTap: _pickStyle),
          ],
        ),
        if (_needsCloud) ...[
          const SizedBox(height: 12),
          Text(
              blocked
                  ? 'Imported files need cloud transcription, which is not set up in this build.'
                  : 'You chose “On this phone” in Settings. Imported files can only be transcribed in the cloud for now; the audio is deleted there after the transcript.',
              style: LnText.meta),
        ],
        const SizedBox(height: 18),
        LnPrimaryButton(
          label: _needsCloud ? 'Import and transcribe in the cloud' : 'Import and transcribe',
          onPressed: blocked ? null : _start,
        ),
      ]),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow(
      {required this.icon,
      required this.label,
      required this.value,
      required this.onTap});
  final LnIcons icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        pressedOpacity: 0.6,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            LnIcon(icon, size: 20),
            const SizedBox(width: 12),
            Text(label, style: LnText.rowLabel),
            const SizedBox(width: 8),
            Expanded(
              child: Text(value,
                  maxLines: 1,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: LnText.rowValue),
            ),
            const SizedBox(width: 6),
            const LnIcon(LnIcons.chevronRight, size: 16, color: LnColors.ink3),
          ]),
        ),
      );
}

class _StylePicker extends StatelessWidget {
  const _StylePicker({required this.current});
  final SummaryStyle current;
  @override
  Widget build(BuildContext context) {
    const all = SummaryStyle.values;
    return LnPlainSheet(
      title: 'Summary style',
      scrollable: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(children: [
        for (var i = 0; i < all.length; i++)
          LnCardSlice(
            first: i == 0,
            last: i == all.length - 1,
            child: LnCheckRow(
              label: all[i].label,
              subtitle: all[i].description,
              checked: all[i] == current,
              onTap: () => Navigator.of(context).pop(all[i]),
            ),
          ),
      ]),
    );
  }
}
