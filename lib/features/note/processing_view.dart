import 'package:flutter/widgets.dart';

import '../../core/models/recording.dart';
import '../../ui/widgets.dart';
import 'kit.dart';
import 'note_model.dart';

enum _Step { done, active, waiting, todo }

class _StepRow {
  const _StepRow(this.state, this.title, this.subtitle, [this.trailing]);
  final _Step state;
  final String title;
  final String subtitle;
  final String? trailing;
}

String? _pct(double? v) => v == null ? null : '${(v * 100).clamp(0, 100).round()}%';

/// D1 (Figma 7:235): the real pipeline state as named steps, plus where the
/// audio goes. [cloud] = this note goes through the cloud pipeline.
List<Widget> processingChildren(
  NoteData d, {
  required bool cloud,
  required VoidCallback onWhereAudioGoes,
  VoidCallback? onBackToRecording,
}) {
  final n = d.note;
  final st = n.processingStatus;
  final parts = d.playable.length;
  final saved = _StepRow(_Step.done, 'Saved on your phone',
      '${clockText(n.durationMs)} of audio · $parts ${parts == 1 ? 'part' : 'parts'}');

  if (n.status.isLive) {
    return [
      _card([
        const _StepRow(_Step.active, 'Recording', 'Audio is saved as it goes'),
        const _StepRow(_Step.todo, 'Writing the transcript', 'Starts when you stop'),
        const _StepRow(_Step.todo, 'Summary', 'Decisions, action items, numbers'),
      ]),
      if (onBackToRecording != null) ...[
        const SizedBox(height: 14),
        LnPrimaryButton(label: 'Back to recording', onPressed: onBackToRecording),
      ],
    ];
  }

  final progressText = n.processingProgress;
  final rows = <_StepRow>[saved];
  const summaryTodo =
      _StepRow(_Step.todo, 'Summary', 'Decisions, action items, numbers');

  if (cloud) {
    final upload = switch (st) {
      ProcessingStatus.none ||
      ProcessingStatus.queued =>
        _StepRow(_Step.active, 'Uploading securely',
            n.tries > 0 && progressText != null ? progressText : 'Waiting to start'),
      ProcessingStatus.compressing =>
        const _StepRow(_Step.active, 'Uploading securely', 'Preparing the audio'),
      ProcessingStatus.uploading => _StepRow(_Step.active, 'Uploading securely',
          'Encrypted in transit', _pct(n.progress)),
      ProcessingStatus.waitingForNetwork => const _StepRow(_Step.waiting,
          'Waiting for internet', 'Uploads by itself when you are online'),
      _ => const _StepRow(_Step.done, 'Uploaded securely', 'Encrypted in transit'),
    };
    rows.add(upload);
    final transcript = switch (st) {
      ProcessingStatus.queuedOnServer => const _StepRow(
          _Step.active, 'Writing the transcript', 'In the queue on our server'),
      ProcessingStatus.transcribing => _StepRow(_Step.active,
          'Writing the transcript', 'Finding who spoke', _pct(n.progress)),
      ProcessingStatus.summarizing || ProcessingStatus.done =>
        const _StepRow(_Step.done, 'Transcript ready', 'Speakers and times'),
      _ => const _StepRow(_Step.todo, 'Writing the transcript', 'Finding who spoke'),
    };
    rows.add(transcript);
  } else {
    final transcript = switch (st) {
      ProcessingStatus.queued || ProcessingStatus.none => _StepRow(_Step.active,
          'Writing the transcript', progressText ?? 'On this phone · waiting to start'),
      ProcessingStatus.transcribing => _StepRow(_Step.active,
          'Writing the transcript', progressText ?? 'On this phone'),
      ProcessingStatus.summarizing || ProcessingStatus.done =>
        const _StepRow(_Step.done, 'Transcript ready', 'Made on this phone'),
      _ => _StepRow(_Step.active, 'Writing the transcript',
          progressText ?? 'On this phone'),
    };
    rows.add(transcript);
  }
  rows.add(st == ProcessingStatus.summarizing
      ? _StepRow(_Step.active, 'Summary', progressText ?? 'Writing the summary')
      : summaryTodo);

  return [
    _card(rows),
    const SizedBox(height: 14),
    _InfoBox(
      icon: const NoteIcon(NoteIcons.bell, size: 18, color: LnColors.ink2),
      children: const [
        TextSpan(
            text:
                'You can leave this screen or close the app. We’ll tell you when the note is ready.')
      ],
    ),
    const SizedBox(height: 10),
    LnPressable(
      onPressed: onWhereAudioGoes,
      semanticLabel: 'What happens to your audio',
      child: _InfoBox(
        icon: const LnIcon(LnIcons.lock, size: 18, color: LnColors.ink2),
        children: [
          TextSpan(
              text: cloud
                  ? 'Your audio goes to our speech-to-text provider and is deleted from our servers once the transcript is done. '
                  : 'Your audio stays on this phone. The transcript is made here and nothing is uploaded. '),
          TextSpan(
              text: 'What happens to your audio',
              style: LnText.preview.copyWith(
                  color: LnColors.ink, decoration: TextDecoration.underline)),
        ],
      ),
    ),
  ];
}

Widget _card(List<_StepRow> rows) => Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: LnColors.card,
        borderRadius: BorderRadius.circular(LnRadius.card),
        border: Border.all(color: LnColors.line),
      ),
      child: Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const LnHairline(),
          _StepTile(row: rows[i]),
        ]
      ]),
    );

class _StepTile extends StatelessWidget {
  const _StepTile({required this.row});
  final _StepRow row;
  @override
  Widget build(BuildContext context) {
    final Widget mark = switch (row.state) {
      _Step.done => Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration:
              const BoxDecoration(color: LnColors.savedTint, shape: BoxShape.circle),
          child: const LnIcon(LnIcons.check, size: 14, color: LnColors.saved)),
      _Step.active => Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: LnColors.ink, width: 2)),
          child: Container(
              width: 10,
              height: 10,
              decoration:
                  const BoxDecoration(color: LnColors.ink, shape: BoxShape.circle))),
      _Step.waiting => Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
              color: LnColors.attentionTint, shape: BoxShape.circle),
          child: const LnIcon(LnIcons.cloudOff, size: 14, color: LnColors.attention)),
      _Step.todo => Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: LnColors.line, width: 2))),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        mark,
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(row.title,
                style: LnText.rowTitleSmall.copyWith(
                    color: row.state == _Step.todo ? LnColors.ink3 : LnColors.ink)),
            const SizedBox(height: 2),
            Text(row.subtitle,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: LnText.meta),
          ]),
        ),
        if (row.trailing != null) ...[
          const SizedBox(width: 12),
          Text(row.trailing!,
              style: LnText.mono.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  fontVariations: const [FontVariation('wght', 500)])),
        ],
      ]),
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.icon, required this.children});
  final Widget icon;
  final List<TextSpan> children;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
            color: LnColors.fill, borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: icon),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(TextSpan(style: LnText.preview, children: children)),
          ),
        ]),
      );
}

/// D8 (Figma 8:923): processing failed. Never hides it, never loses audio.
List<Widget> failedChildren(
  NoteData d, {
  required bool canUsePhone,
  required VoidCallback onTryAgain,
  required VoidCallback onTranscribeOnPhone,
  required VoidCallback onSendReport,
}) {
  final n = d.note;
  final limit = n.errorCode == 'limit_reached';
  final tooLong = n.errorCode == 'too_long';
  final reason = (n.processingError ?? '').trim();
  final tried = n.tries > 1 ? ' We tried ${n.tries} times.' : '';
  final body = 'Your audio is safe on this phone — all '
      '${spokenLength(n.duration)} of it.$tried'
      '${reason.isEmpty ? '' : ' $reason'}';
  return [
    Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: LnColors.attentionTint,
        borderRadius: BorderRadius.circular(LnRadius.card),
        border: Border.all(color: const Color(0xFFEED8AE)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const LnIcon(LnIcons.alert, size: 20, color: LnColors.attention),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                limit
                    ? 'Today’s limit is reached'
                    : tooLong
                        ? 'Longer than 5 hours'
                        : 'We couldn’t make the transcript',
                style: LnText.rowTitle),
          ),
        ]),
        const SizedBox(height: 10),
        Text(body,
            style: LnText.body.copyWith(
                fontSize: 15, height: 22 / 15, color: const Color(0xFF5A4A2E))),
        const SizedBox(height: 10),
        Row(children: [
          const LnIcon(LnIcons.check, size: 14, color: LnColors.saved),
          const SizedBox(width: 6),
          Text(d.playable.isEmpty ? 'Audio saved' : 'Audio saved · plays below',
              style: LnText.caption.copyWith(color: LnColors.saved)),
        ]),
      ]),
    ),
    const SizedBox(height: 16),
    LnPrimaryButton(label: 'Try again', onPressed: onTryAgain),
    if (canUsePhone) ...[
      const SizedBox(height: 10),
      LnPressable(
        onPressed: onTranscribeOnPhone,
        semanticLabel: 'Transcribe on this phone instead',
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: LnColors.card,
            borderRadius: BorderRadius.circular(LnRadius.button),
            border: Border.all(color: LnColors.line),
          ),
          child: Column(children: [
            Text('Transcribe on this phone instead', style: LnText.rowTitleSmall),
            const SizedBox(height: 2),
            Text('Works offline · slower · no speaker labels',
                style: LnText.chip.copyWith(fontWeight: FontWeight.w400,
                    fontVariations: const [FontVariation('wght', 400)])),
          ]),
        ),
      ),
    ],
    const SizedBox(height: 18),
    LnPressable(
      onPressed: onSendReport,
      semanticLabel: 'Send the error report',
      child: Text.rich(TextSpan(
          style: LnText.meta.copyWith(height: 19 / 13),
          children: [
            TextSpan(
                text: limit
                    ? 'It will try again by itself when the limit resets. Need help? '
                    : 'Need help? '),
            TextSpan(
                text: 'Send us the error report',
                style: LnText.meta.copyWith(
                    height: 19 / 13,
                    color: LnColors.ink,
                    decoration: TextDecoration.underline)),
            const TextSpan(text: ' — it contains no audio.'),
          ])),
    ),
  ];
}
