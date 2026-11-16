import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/models/recording.dart';
import '../../ui/widgets.dart';
import '../common/widgets.dart';

/// G3 Transcription & privacy (Figma 10:879): cloud (default) vs on this
/// phone, where the audio goes for the chosen mode, and the iCloud backup
/// switch (really sets the exclude-from-backup flag on the recordings folder
/// through `AppServices.setExcludeFromBackup`, native `longnote/files`).
class TranscriptionScreen extends StatefulWidget {
  const TranscriptionScreen({super.key});
  @override
  State<TranscriptionScreen> createState() => _TranscriptionScreenState();
}

class _TranscriptionScreenState extends State<TranscriptionScreen> {
  TranscriptionMode? _mode;
  bool? _backup;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final st = context.read<AppServices>().settings;
      final m = await st.transcriptionMode();
      final excluded = await st.excludeFromBackup();
      if (mounted) {
        setState(() {
          _mode = m;
          _backup = !excluded;
        });
      }
    });
  }

  Future<void> _setMode(TranscriptionMode m) async {
    setState(() => _mode = m);
    await context.read<AppServices>().settings.setTranscriptionMode(m);
  }

  Future<void> _setBackup(bool on) async {
    setState(() => _backup = on);
    await context.read<AppServices>().setExcludeFromBackup(!on);
  }

  @override
  Widget build(BuildContext context) {
    final cloud = (_mode ?? TranscriptionMode.cloud) == TranscriptionMode.cloud;
    return Scaffold(
      backgroundColor: LnColors.paper,
      appBar: const LnNavBar(title: 'Transcription', backLabel: 'Settings'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 40),
        children: [
          _ModeCard(
            title: 'Cloud',
            tag: 'Recommended',
            text:
                'Most accurate. Knows who spoke. Audio is sent to our speech-to-text provider, then deleted from their servers and ours.',
            selected: _mode == TranscriptionMode.cloud,
            onTap: () => _setMode(TranscriptionMode.cloud),
          ),
          const SizedBox(height: 10),
          _ModeCard(
            title: 'On this phone',
            text:
                'Audio never leaves your phone. Slower, uses battery, and no speaker labels.',
            selected: _mode == TranscriptionMode.onDevice,
            onTap: () => _setMode(TranscriptionMode.onDevice),
          ),
          const SizedBox(height: 18),
          LnSectionLabel(cloud
              ? 'Where your audio goes (Cloud)'
              : 'Where your audio goes (On this phone)'),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOut,
            child: LnCard(
              key: ValueKey(cloud),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                  children: cloud
                      ? const [
                          _Hop(LnIcons.phone, 'Your phone',
                              'Keeps the original audio until you delete it'),
                          _Hop(LnIcons.cloud, 'Speech-to-text provider',
                              'Makes the transcript, then deletes the audio'),
                          _Hop(LnIcons.trash, 'Our server',
                              'Deletes the audio as soon as the transcript is back'),
                        ]
                      : const [
                          _Hop(LnIcons.phone, 'Your phone',
                              'Records and transcribes here. The audio is never uploaded.'),
                          _Hop(LnIcons.text, 'Summaries and Ask',
                              'Send the transcript text, never the audio'),
                        ]),
            ),
          ),
          const SizedBox(height: 14),
          LnCardGroup.settings(children: [
            LnListRow.toggle(
              icon: LnIcons.backup,
              label: 'Back up recordings to iCloud',
              subtitle: 'Off saves iCloud space; audio stays on this phone',
              value: _backup ?? true,
              onChanged: _backup == null ? null : _setBackup,
            ),
          ]),
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.title,
    required this.text,
    required this.selected,
    required this.onTap,
    this.tag,
  });
  final String title;
  final String text;
  final String? tag;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        child: LnPressable(
          onPressed: onTap,
          pressedOpacity: 0.8,
          child: LnCard(
            selected: selected,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              LnRadioMark(selected: selected),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(title, style: LnText.rowTitle),
                        if (tag != null) ...[
                          const SizedBox(width: 8),
                          LnGreenTag(tag!),
                        ],
                      ]),
                      const SizedBox(height: 4),
                      Text(text,
                          style: LnText.preview),
                    ]),
              ),
            ]),
          ),
        ),
      );
}

class _Hop extends StatelessWidget {
  const _Hop(this.icon, this.title, this.text);
  final LnIcons icon;
  final String title;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          LnIconTile(icon, size: 32, iconSize: 16),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: LnText.speakerName),
              const SizedBox(height: 1),
              Text(text, style: LnText.meta),
            ]),
          ),
        ]),
      );
}
