import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/models/recording.dart';
import '../../core/summary/summary_style.dart';
import '../../ui/widgets.dart';
import 'kit.dart';
import 'summary_view.dart';

/// D6 Summary style (Figma 8:470): nine styles plus "Your own instructions".
/// With a note [id], Apply saves the choice on the note and rewrites its
/// summary. Without an id it sets the default style for new notes.
class SummaryStyleSheet extends StatefulWidget {
  const SummaryStyleSheet({super.key, this.id});

  /// Null = the default style in Settings.
  final String? id;

  @override
  State<SummaryStyleSheet> createState() => _SummaryStyleSheetState();
}

class _SummaryStyleSheetState extends State<SummaryStyleSheet> {
  late final AppServices _s = context.read<AppServices>();
  SummaryStyle? _style;
  final _own = TextEditingController();
  bool _ownOpen = false;
  bool _asDefault = false;
  bool _busy = false;
  Recording? _note;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.id;
    final def = await _s.settings.defaultStyle();
    Recording? note;
    if (id != null) note = await _s.repo.get(id);
    if (!mounted) return;
    setState(() {
      _note = note;
      _style = note?.summaryStyle == null ? def : SummaryStyle.parse(note!.summaryStyle);
      final own = note?.customInstructions?.trim() ?? '';
      _own.text = own;
      _ownOpen = own.isNotEmpty;
    });
  }

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final style = _style;
    if (style == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    final id = widget.id;
    if (id == null) {
      await _s.settings.setDefaultStyle(style);
      if (mounted) context.pop(true);
      return;
    }
    final own = _ownOpen ? _own.text.trim() : '';
    await _s.repo.setNoteOptions(id,
        summaryStyle: style.id,
        customInstructions: own.isEmpty ? null : own,
        clear: own.isEmpty ? const ['custom_instructions'] : const []);
    if (_asDefault) await _s.settings.setDefaultStyle(style);
    if (mounted) context.pop(true);
    await _resummarize(id, messenger);
  }

  /// Cloud notes are rewritten directly; on-device notes go through the
  /// queue (their transcript is kept, only the summary is redone).
  Future<void> _resummarize(String id, ScaffoldMessengerState? messenger) async {
    final cloud = _s.cloud;
    final note = _note;
    if (cloud != null && note?.transcriptSource == 'cloud') {
      try {
        await cloud.resummarize(id);
      } catch (_) {
        await _s.repo.setProcessing(id, ProcessingStatus.done);
        messenger?.showSnackBar(const SnackBar(
            content: Text(
                'Couldn’t rewrite the summary. Check your connection and try again.')));
      }
    } else {
      await _s.jobs.enqueue(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _style;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: LnSheet(
        title: 'Summary style',
        scrollable: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
        leadingAction: LnSheetAction('Cancel', onPressed: () => context.pop()),
        trailingAction: LnSheetAction(widget.id == null ? 'Save' : 'Apply',
            emphasized: true,
            onPressed: selected == null || _busy ? null : _apply),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                widget.id == null
                    ? 'Pick how new notes are summarised. You can change it per note.'
                    : 'Pick how this note is summarised. Your transcript stays the same.',
                style: LnText.preview),
            const SizedBox(height: 14),
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: LnColors.card,
                borderRadius: BorderRadius.circular(LnRadius.card),
                border: Border.all(color: LnColors.line),
              ),
              child: Column(children: [
                for (final st in SummaryStyle.values) ...[
                  if (st.index > 0)
                    const Padding(
                        padding: EdgeInsets.only(left: 60), child: LnHairline()),
                  _StyleRow(
                    look: styleLook(st),
                    selected: st == selected,
                    onTap: () => setState(() => _style = st),
                  ),
                ],
              ]),
            ),
            if (widget.id != null) ...[
              const SizedBox(height: 12),
              _OwnInstructions(
                open: _ownOpen,
                controller: _own,
                onOpen: () => setState(() => _ownOpen = true),
                onClear: () => setState(() {
                  _ownOpen = false;
                  _own.clear();
                }),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(children: [
                  Expanded(
                    child: Text('Use this style for new notes',
                        style: LnText.segment),
                  ),
                  LnToggle(
                    small: true,
                    value: _asDefault,
                    semanticLabel: 'Use this style for new notes',
                    onChanged: (v) => setState(() => _asDefault = v),
                  ),
                ]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StyleRow extends StatelessWidget {
  const _StyleRow({required this.look, required this.selected, required this.onTap});
  final StyleLook look;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        pressedOpacity: 0.7,
        semanticLabel: look.label,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            IconTile(
              size: 32,
              radius: 9,
              color: selected ? LnColors.ink : LnColors.fill,
              child: NoteIcon(look.icon,
                  size: 16, color: selected ? LnColors.card : LnColors.ink),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(look.label, style: LnText.rowTitleSmall),
                const SizedBox(height: 1),
                Text(look.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: LnText.chip.copyWith(
                        fontWeight: FontWeight.w400,
                        fontVariations: const [FontVariation('wght', 400)])),
              ]),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              const LnIcon(LnIcons.check, size: 18),
            ],
          ]),
        ),
      );
}

class _OwnInstructions extends StatelessWidget {
  const _OwnInstructions({
    required this.open,
    required this.controller,
    required this.onOpen,
    required this.onClear,
  });
  final bool open;
  final TextEditingController controller;
  final VoidCallback onOpen;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final header = Row(children: [
      const IconTile(size: 32, radius: 9, child: NoteIcon(NoteIcons.stylePlus, size: 16)),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Your own instructions', style: LnText.rowTitleSmall),
          const SizedBox(height: 1),
          Text('e.g. “List every number and who said it”',
              style: LnText.chip.copyWith(
                  fontWeight: FontWeight.w400,
                  fontVariations: const [FontVariation('wght', 400)])),
        ]),
      ),
      if (open)
        LnPressable(
          onPressed: onClear,
          semanticLabel: 'Remove own instructions',
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: LnIcon(LnIcons.x, size: 16, color: LnColors.ink2),
          ),
        ),
    ]);
    return LnPressable(
      onPressed: open ? null : onOpen,
      pressedOpacity: 0.7,
      child: CustomPaint(
        painter: open ? null : const _DashedBorder(),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: open
              ? BoxDecoration(
                  color: LnColors.card,
                  borderRadius: BorderRadius.circular(LnRadius.card),
                  border: Border.all(color: LnColors.line))
              : null,
          child: Column(children: [
            header,
            if (open) ...[
              const SizedBox(height: 12),
              LnTextField(
                controller: controller,
                maxLines: 4,
                maxLength: maxCustomInstructionsChars,
                autofocus: controller.text.isEmpty,
                hint: 'Tell us what the summary should contain',
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// 1 px dashed ink3 rounded border (Figma "Your own instructions").
class _DashedBorder extends CustomPainter {
  const _DashedBorder();
  @override
  void paint(Canvas canvas, Size size) {
    final rr = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(LnRadius.card));
    final path = Path()..addRRect(rr.deflate(0.5));
    final paint = Paint()
      ..color = LnColors.ink3
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + 4), paint);
        d += 7;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
