import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/analytics/analytics.dart';
import '../../core/models/recording.dart';
import '../../core/notes/speakers.dart';
import '../../ui/widgets.dart';
import 'kit.dart';
import 'note_playback.dart';

/// D4 Edit speaker names (Figma 7:546): Cancel | Speakers | Save, one card
/// per voice with a name field and a playable sample, plus "Merge speakers".
class SpeakersSheet extends StatefulWidget {
  const SpeakersSheet({super.key, required this.id});
  final String id;

  @override
  State<SpeakersSheet> createState() => _SpeakersSheetState();
}

class _SpeakersSheetState extends State<SpeakersSheet> {
  late final AppServices _s = context.read<AppServices>();
  List<Speaker>? _speakers;
  Map<String, TranscriptLine> _samples = const {};
  final _ctl = <String, TextEditingController>{};
  final _focus = <String, FocusNode>{};
  String? _focused;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _s.speakers.list(widget.id);
    final samples = await _s.speakers.firstTurns(widget.id);
    if (!mounted) return;
    for (final sp in list) {
      _ctl.putIfAbsent(sp.key, () {
        // Default names stay as the hint, so typing replaces them.
        final isDefault = sp.name == defaultSpeakerName(sp.key);
        return TextEditingController(text: isDefault ? '' : sp.name);
      });
      _focus.putIfAbsent(sp.key, () {
        final f = FocusNode();
        f.addListener(() {
          if (f.hasFocus) setState(() => _focused = sp.key);
        });
        return f;
      });
    }
    setState(() {
      _speakers = list;
      _samples = samples;
    });
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final list = _speakers;
    if (list == null) return;
    setState(() => _saving = true);
    var renamed = 0;
    for (final sp in list) {
      final v = _ctl[sp.key]!.text.trim();
      final target = v.isEmpty ? defaultSpeakerName(sp.key) : v;
      if (target != sp.name) {
        await _s.speakers.rename(widget.id, sp.key, target);
        renamed++;
      }
    }
    // How many, never the names.
    if (renamed > 0) {
      _s.analytics.log(AnalyticsEvent.speakerRenamed,
          recordingId: widget.id, props: {'count': renamed});
    }
    if (mounted) context.pop(true);
  }

  Future<void> _playSample(TranscriptLine l) async {
    final p = NotePlaybacks.peek(widget.id);
    if (p == null) {
      showToast(context, 'The audio is not ready to play.');
      return;
    }
    await p.playClip(l.startMs, l.endMs.clamp(l.startMs + 1000, l.startMs + 8000));
  }

  Future<void> _merge() async {
    final list = _speakers;
    if (list == null || list.length < 2) return;
    final pair = await showLnSheet<(String, String)>(
      context,
      builder: (c) => _MergeSheet(speakers: list, nameOf: _nameOf),
    );
    if (pair == null) return;
    await _s.speakers.merge(widget.id, fromKey: pair.$1, intoKey: pair.$2);
    await _load();
    // Dispose only after the frame that stops using them.
    final ctl = _ctl.remove(pair.$1);
    final focus = _focus.remove(pair.$1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ctl?.dispose();
      focus?.dispose();
    });
    if (mounted) showToast(context, 'Speakers merged');
  }

  String _nameOf(Speaker sp) {
    final v = _ctl[sp.key]?.text.trim() ?? '';
    return v.isEmpty ? sp.name : v;
  }

  @override
  Widget build(BuildContext context) {
    final list = _speakers;
    final count = list?.length ?? 0;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: LnSheet(
        title: 'Speakers',
        scrollable: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        leadingAction:
            LnSheetAction('Cancel', onPressed: () => context.pop()),
        trailingAction: LnSheetAction('Save',
            emphasized: true, onPressed: list == null || _saving ? null : _save),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                count == 0
                    ? 'No voices were found in this note.'
                    : 'We found $count ${count == 1 ? 'voice' : 'voices'}. Name them once and the transcript, summary and exports update.',
                style: LnText.preview),
            const SizedBox(height: 16),
            for (final sp in list ?? const <Speaker>[]) ...[
              _SpeakerCard(
                speaker: sp,
                controller: _ctl[sp.key]!,
                focusNode: _focus[sp.key]!,
                focused: _focused == sp.key,
                sample: _samples[sp.key],
                onPlay: _samples[sp.key] == null
                    ? null
                    : () => _playSample(_samples[sp.key]!),
              ),
              const SizedBox(height: 10),
            ],
            if (count > 1)
              LnPressable(
                onPressed: _merge,
                semanticLabel: 'Merge speakers',
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text.rich(TextSpan(style: LnText.meta, children: [
                    const TextSpan(text: 'Two of these are the same person?  '),
                    TextSpan(
                        text: 'Merge speakers',
                        style: LnText.smallButton.copyWith(
                            fontWeight: FontWeight.w600)),
                  ])),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SpeakerCard extends StatelessWidget {
  const _SpeakerCard({
    required this.speaker,
    required this.controller,
    required this.focusNode,
    required this.focused,
    this.sample,
    this.onPlay,
  });
  final Speaker speaker;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool focused;
  final TranscriptLine? sample;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      padding: EdgeInsets.all(focused ? 13 : 14),
      decoration: BoxDecoration(
        color: LnColors.card,
        borderRadius: BorderRadius.circular(LnRadius.card),
        border: Border.all(
            color: focused ? LnColors.ink : LnColors.line, width: focused ? 2 : 1),
      ),
      child: Column(children: [
        Row(children: [
          LnSpeakerAvatar(
              name: controller.text.isEmpty ? speaker.name : controller.text,
              colorIndex: speaker.colorIndex),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                  color: LnColors.fill,
                  borderRadius: BorderRadius.circular(LnRadius.iconButton)),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textCapitalization: TextCapitalization.words,
                style: LnText.body.copyWith(fontSize: 15, height: 1.33),
                cursorColor: LnColors.ink,
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: speaker.name,
                  hintStyle: LnText.placeholder.copyWith(fontSize: 15),
                ),
              ),
            ),
          ),
        ]),
        if (sample != null) ...[
          const SizedBox(height: 10),
          Row(children: [
            LnPressable(
              onPressed: onPlay,
              semanticLabel: 'Play a clip of ${speaker.name}',
              child: Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                    color: LnColors.fill, shape: BoxShape.circle),
                child: const LnIcon(LnIcons.play, size: 10),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('“${sample!.text}”',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: LnText.meta),
            ),
            const SizedBox(width: 8),
            Text(clockText(sample!.startMs), style: LnText.monoTiny.copyWith(
                color: LnColors.ink3)),
          ]),
        ],
      ]),
    );
  }
}

/// "This voice … is the same person as …" picker.
class _MergeSheet extends StatefulWidget {
  const _MergeSheet({required this.speakers, required this.nameOf});
  final List<Speaker> speakers;
  final String Function(Speaker) nameOf;
  @override
  State<_MergeSheet> createState() => _MergeSheetState();
}

class _MergeSheetState extends State<_MergeSheet> {
  String? _from;
  String? _into;

  Widget _chips(String? selected, ValueChanged<String> onTap, {String? except}) =>
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final sp in widget.speakers)
          if (sp.key != except)
            LnPillChip(
              label: widget.nameOf(sp),
              selected: sp.key == selected,
              onTap: () => onTap(sp.key),
            ),
      ]);

  @override
  Widget build(BuildContext context) {
    final ready = _from != null && _into != null && _from != _into;
    return LnSheet(
      title: 'Merge speakers',
      subtitle: 'Their lines become one voice. The audio is not changed.',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LnSectionLabel('This voice'),
          _chips(_from, (k) => setState(() {
                _from = k;
                if (_into == k) _into = null;
              })),
          const SizedBox(height: 16),
          const LnSectionLabel('is the same person as'),
          _chips(_into, (k) => setState(() => _into = k), except: _from),
          const SizedBox(height: 20),
          LnPrimaryButton(
            label: 'Merge',
            onPressed: ready ? () => Navigator.of(context).pop((_from!, _into!)) : null,
          ),
          const SizedBox(height: 8),
          LnSecondaryButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }
}
