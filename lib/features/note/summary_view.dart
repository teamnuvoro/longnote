import 'package:flutter/widgets.dart';

import '../../core/models/recording.dart';
import '../../core/summary/summary_models.dart';
import '../../core/summary/summary_style.dart';
import '../../ui/widgets.dart';
import 'kit.dart';
import 'note_model.dart';

/// How each summary style is shown (Figma D6 8:470 copy and icons).
class StyleLook {
  const StyleLook(this.label, this.description, this.icon);
  final String label;
  final String description;
  final NoteIcons icon;
}

StyleLook styleLook(SummaryStyle s) => switch (s) {
      SummaryStyle.meeting => const StyleLook(
          'Meeting notes', 'Decisions, action items, owners', NoteIcons.styleUsers),
      SummaryStyle.lecture => const StyleLook('Lecture → study notes',
          'Key ideas, terms, likely exam points', NoteIcons.styleBook),
      SummaryStyle.oneOnOne => const StyleLook(
          '1:1 or check-in', 'Updates, blockers, follow-ups', NoteIcons.styleChat),
      SummaryStyle.interview => const StyleLook(
          'Interview', 'Questions, answers, best quotes', NoteIcons.styleMic),
      SummaryStyle.clientCall => const StyleLook('Client or sales call',
          'Needs, objections, next steps', NoteIcons.styleHandshake),
      SummaryStyle.brainstorm => const StyleLook(
          'Brainstorm', 'Ideas grouped by theme', NoteIcons.styleBulb),
      SummaryStyle.sermon => const StyleLook('Sermon or talk',
          'Main message, stories, takeaways', NoteIcons.styleChurch),
      SummaryStyle.doctorVisit => const StyleLook('Doctor visit',
          'What was said, medicines, next visit', NoteIcons.styleHeart),
      SummaryStyle.voiceMemoTodos => const StyleLook('Voice memo → to-dos',
          'Your thoughts as a task list', NoteIcons.styleTodo),
    };

/// D2 Summary tab body (Figma 7:332). Returns plain widgets for a sliver list.
List<Widget> summaryChildren(
  NoteData d, {
  required VoidCallback onChangeStyle,
  required VoidCallback onMakeSummary,
  VoidCallback? onEdit,
}) {
  final s = d.summary;
  final note = d.note;
  final custom = (note.customInstructions ?? '').trim().isNotEmpty;
  final look = styleLook(SummaryStyle.parse(note.summaryStyle));
  final rewriting = note.processingStatus == ProcessingStatus.summarizing;

  final out = <Widget>[
    Row(children: [
      const LnIcon(LnIcons.template, size: 15, color: LnColors.ink2),
      const SizedBox(width: 6),
      Expanded(
        child: Text(custom ? 'Your own instructions' : look.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: LnText.caption),
      ),
      // Not while the note is being (re)processed: a new summary is coming.
      if (onEdit != null &&
          s != null &&
          !s.isEmpty &&
          !note.processingStatus.inProgress) ...[
        LnPressable(
          onPressed: onEdit,
          semanticLabel: 'Edit summary',
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const LnIcon(LnIcons.pencil, size: 14),
              const SizedBox(width: 4),
              Text('Edit', style: LnText.smallButton),
            ]),
          ),
        ),
        const SizedBox(width: 16),
      ],
      LnPressable(
        onPressed: rewriting ? null : onChangeStyle,
        semanticLabel: 'Change style',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('Change style', style: LnText.smallButton),
            const SizedBox(width: 4),
            const LnIcon(LnIcons.chevronDown, size: 14),
          ]),
        ),
      ),
    ]),
    const SizedBox(height: 14),
  ];

  if (rewriting) {
    out.add(_Notice(
        text: note.processingProgress ?? 'Writing the summary…', busy: true));
    out.add(const SizedBox(height: 16));
  }

  if (s == null || s.isEmpty) {
    if (!rewriting) {
      out.add(Text(
          d.summaryNote ??
              (s == null
                  ? 'There is no summary for this note yet.'
                  : 'The summary came back empty.'),
          style: LnText.bullet.copyWith(color: LnColors.ink2)));
      out.add(const SizedBox(height: 14));
      out.add(Align(
        alignment: Alignment.centerLeft,
        child: LnPillButton(
            label: 'Make a summary',
            icon: LnIcons.sparkle,
            style: LnPillStyle.outline,
            onPressed: onMakeSummary),
      ));
    }
    return out;
  }

  if (s.inShort != null && s.inShort!.isNotEmpty) {
    out.add(Text(s.inShort!, style: LnText.summaryLead));
    out.add(const SizedBox(height: 18));
  }
  void section(String title, List<Widget> rows, {double after = 12}) {
    if (rows.isEmpty) return;
    out.add(LnOverline(title));
    out.add(const SizedBox(height: 8));
    out.addAll(rows);
    out.add(SizedBox(height: after));
  }

  final keyPoints = [for (final k in s.keyPoints) _Bullet(text: k)];
  if (s.inShort == null) section('Key points', keyPoints);
  section('Decisions', [for (final t in s.decisions) _Bullet(text: t, check: true)]);
  section('Action items', [
    for (var i = 0; i < s.actionItems.length; i++) ...[
      if (i > 0) const SizedBox(height: 8),
      _ActionCard(item: s.actionItems[i], data: d),
    ]
  ], after: 18);
  if (s.inShort != null) section('Key points', keyPoints);
  section('Numbers and dates', [for (final t in s.numbersAndDates) _Bullet(text: t)]);
  section('Open questions', [for (final t in s.openQuestions) _Bullet(text: t)]);
  if (d.summaryNote != null) {
    out.add(Text(d.summaryNote!, style: LnText.meta.copyWith(color: LnColors.ink3)));
  }
  if (s.edited) {
    out.add(const SizedBox(height: 4));
    out.add(Text('Edited by you', style: LnText.meta.copyWith(color: LnColors.ink3)));
  }
  return out;
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.text, this.check = false});
  final String text;
  final bool check;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (check)
            Container(
              width: 18,
              height: 18,
              margin: const EdgeInsets.only(top: 1.5),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: LnColors.savedTint, borderRadius: BorderRadius.circular(5)),
              child: const LnIcon(LnIcons.check, size: 11, color: LnColors.saved),
            )
          else
            Container(
              width: 18,
              height: 21,
              alignment: Alignment.center,
              child: Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                    color: LnColors.ink3, shape: BoxShape.circle),
              ),
            ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: LnText.bullet)),
        ]),
      );
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.item, required this.data});
  final ActionItem item;
  final NoteData data;
  @override
  Widget build(BuildContext context) {
    final owner = item.owner;
    final due = item.due;
    final meta = LnText.caption;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: LnColors.card,
        borderRadius: BorderRadius.circular(LnRadius.actionCard),
        border: Border.all(color: LnColors.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(item.task,
            style: LnText.bullet.copyWith(
                fontWeight: FontWeight.w500,
                fontVariations: const [FontVariation('wght', 500)])),
        // Owner and date only when someone actually said them.
        if (owner != null || due != null) ...[
          const SizedBox(height: 6),
          Row(children: [
            if (owner != null) ...[
              _OwnerDot(name: owner, colorIndex: data.colorForOwner(owner)),
              const SizedBox(width: 8),
              Flexible(
                  child: Text(owner,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: meta)),
            ],
            if (owner != null && due != null) ...[
              const SizedBox(width: 8),
              Text('·', style: LnText.meta.copyWith(color: LnColors.ink3)),
              const SizedBox(width: 8),
            ],
            if (due != null)
              Flexible(
                  child: Text(due,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: meta)),
          ]),
        ],
      ]),
    );
  }
}

class _OwnerDot extends StatelessWidget {
  const _OwnerDot({required this.name, this.colorIndex});
  final String name;
  final int? colorIndex;
  @override
  Widget build(BuildContext context) {
    if (colorIndex != null) {
      return LnSpeakerAvatar(name: name, colorIndex: colorIndex!, size: 18);
    }
    final t = name.trim();
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: LnColors.ink3, shape: BoxShape.circle),
      child: Text(t.isEmpty ? '?' : t.characters.first.toUpperCase(),
          style: LnText.smallButton.copyWith(color: LnColors.card, fontSize: 10)),
    );
  }
}

/// Quiet grey info box (D1 "You can leave this screen…").
class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.busy = false});
  final String text;
  final bool busy;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
            color: LnColors.fill, borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          if (busy) ...[
            const SizedBox(
                width: 14,
                height: 14,
                child: _Spinner()),
            const SizedBox(width: 10),
          ],
          Expanded(child: Text(text, style: LnText.preview)),
        ]),
      );
}

/// Small ring that does not animate (keeps tests settling; the progress
/// text next to it carries the information).
class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: LnColors.ink2, width: 2),
        ),
      );
}
