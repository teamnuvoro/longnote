import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/analytics/analytics.dart';
import '../../core/summary/summary_models.dart';
import '../../ui/widgets.dart';

/// Summary tab in edit mode: every sentence and point is a text field.
/// Saves by itself ([autosaveDelay] after the last keystroke, and when the
/// editor closes). An emptied point is removed. The transcript is never
/// editable.
class SummaryEditor extends StatefulWidget {
  const SummaryEditor({
    super.key,
    required this.recordingId,
    required this.initial,
    required this.save,
    required this.analytics,
    required this.onDone,
  });

  final String recordingId;
  final MeetingSummary initial;
  final Future<void> Function(MeetingSummary s) save;
  final Analytics analytics;
  final VoidCallback onDone;

  static const autosaveDelay = Duration(milliseconds: 700);

  @override
  State<SummaryEditor> createState() => _SummaryEditorState();
}

class _Field {
  _Field(String text, {this.added = false})
      : ctl = TextEditingController(text: text),
        original = text;
  final TextEditingController ctl;
  final String original;
  final bool added;
  String get text => ctl.text.trim();
}

class _SummaryEditorState extends State<SummaryEditor> {
  late final _Field? _inShort = widget.initial.inShort == null
      ? null
      : _Field(widget.initial.inShort!);
  late final _keyPoints = [for (final t in widget.initial.keyPoints) _Field(t)];
  late final _decisions = [for (final t in widget.initial.decisions) _Field(t)];
  late final _actions = [
    for (final a in widget.initial.actionItems) _Field(a.task)
  ];
  late final _numbers = [
    for (final t in widget.initial.numbersAndDates) _Field(t)
  ];
  late final _questions = [
    for (final t in widget.initial.openQuestions) _Field(t)
  ];

  Timer? _debounce;
  bool _dirty = false;
  bool _saving = false;
  bool _savedOnce = false;

  Iterable<_Field> get _all => [
        ?_inShort,
        ..._keyPoints,
        ..._decisions,
        ..._actions,
        ..._numbers,
        ..._questions,
      ];

  @override
  void initState() {
    super.initState();
    for (final f in _all) {
      f.ctl.addListener(_changed);
    }
  }

  void _changed() {
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(SummaryEditor.autosaveDelay, _save);
  }

  MeetingSummary _build() {
    List<String> texts(List<_Field> l) =>
        [for (final f in l) if (f.text.isNotEmpty) f.text];
    final a = widget.initial.actionItems;
    return MeetingSummary(
      inShort: (_inShort?.text.isEmpty ?? true) ? null : _inShort!.text,
      keyPoints: texts(_keyPoints),
      decisions: texts(_decisions),
      actionItems: [
        for (var i = 0; i < _actions.length; i++)
          if (_actions[i].text.isNotEmpty)
            ActionItem(
                task: _actions[i].text,
                owner: i < a.length ? a[i].owner : null,
                due: i < a.length ? a[i].due : null),
      ],
      numbersAndDates: texts(_numbers),
      openQuestions: texts(_questions),
      edited: true,
    );
  }

  Future<void> _save() async {
    _debounce?.cancel();
    if (!_dirty || _saving) return;
    _dirty = false;
    _saving = true;
    try {
      await widget.save(_build());
      _savedOnce = true;
    } catch (_) {
      _dirty = true; // try again on the next change or on Done
    } finally {
      _saving = false;
      if (mounted) setState(() {});
    }
  }

  /// One summary_edited per session, counts only (never the text).
  void _logSession() {
    var changed = 0, removed = 0, added = 0;
    for (final f in _all) {
      if (f.added) {
        if (f.text.isNotEmpty) added++;
      } else if (f.text.isEmpty) {
        removed++;
      } else if (f.text != f.original.trim()) {
        changed++;
      }
    }
    if (changed + removed + added == 0) return;
    unawaited(widget.analytics.log(AnalyticsEvent.summaryEdited,
        recordingId: widget.recordingId,
        props: {
          'fields_changed': changed,
          'items_removed': removed,
          'items_added': added,
        }));
  }

  Future<void> _done() async {
    FocusScope.of(context).unfocus();
    await _save();
    widget.onDone();
  }

  @override
  void dispose() {
    // Leaving the note (or Done): save what is left, log the session.
    if (_dirty) unawaited(widget.save(_build()).catchError((_) {}));
    _logSession();
    _debounce?.cancel();
    for (final f in _all) {
      f.ctl.dispose();
    }
    super.dispose();
  }

  void _addPoint() {
    final f = _Field('', added: true)..ctl.addListener(_changed);
    setState(() => _keyPoints.add(f));
  }

  @override
  Widget build(BuildContext context) {
    final status = _saving
        ? 'Saving…'
        : _dirty
            ? 'Editing'
            : _savedOnce
                ? 'Saved'
                : 'Changes save by themselves';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const LnIcon(LnIcons.check, size: 14, color: LnColors.ink2),
        const SizedBox(width: 6),
        Expanded(
            child: Text(status,
                key: const ValueKey('summary-edit-status'),
                style: LnText.caption)),
        LnPressable(
          onPressed: _done,
          semanticLabel: 'Done editing',
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('Done', style: LnText.smallButton),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      Text('Edit any sentence or point. Clear a point to remove it. '
          'The transcript stays as it was recorded.',
          style: LnText.meta.copyWith(color: LnColors.ink3)),
      const SizedBox(height: 14),
      if (_inShort != null) ...[
        _Box(field: _inShort, style: LnText.summaryLead, label: 'In short'),
        const SizedBox(height: 18),
      ],
      ..._section('Decisions', _decisions),
      ..._section('Action items', _actions),
      ..._section('Key points', _keyPoints, always: true),
      Align(
        alignment: Alignment.centerLeft,
        child: LnPillButton(
            label: "+ Add a point",
            style: LnPillStyle.outline,
            onPressed: _addPoint),
      ),
      const SizedBox(height: 18),
      ..._section('Numbers and dates', _numbers),
      ..._section('Open questions', _questions),
    ]);
  }

  List<Widget> _section(String title, List<_Field> fields,
      {bool always = false}) {
    if (fields.isEmpty && !always) return const [];
    return [
      LnOverline(title),
      const SizedBox(height: 8),
      for (final f in fields) ...[
        _Box(field: f, style: LnText.bullet, label: title),
        const SizedBox(height: 8),
      ],
      const SizedBox(height: 10),
    ];
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.field, required this.style, required this.label});
  final _Field field;
  final TextStyle style;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: LnColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: LnColors.line),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: TextField(
          controller: field.ctl,
          autofocus: field.added,
          maxLines: null,
          minLines: 1,
          style: style,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            border: InputBorder.none,
            isDense: true,
            hintText: field.added ? 'New point' : 'Removed when empty',
            hintStyle: style.copyWith(color: LnColors.ink3),
            semanticCounterText: label,
          ),
        ),
      );
}
