import 'package:flutter/material.dart';

import '../../app/routes.dart';
import '../../app/nav.dart';
import '../../core/models/recording.dart';
import '../../core/util/clock.dart';
import '../../ui/widgets.dart';
import '../common/dates.dart';
import '../common/widgets.dart';
import 'import_controller.dart';

/// F3 card: file, "Copying to this phone · 53 of 118 MB", cancel, 6 px bar.
class ImportProgressCard extends StatelessWidget {
  const ImportProgressCard({super.key, required this.job, required this.onCancel});
  final ImportJob job;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final failed = job.state == ImportState.failed;
    final line = failed
        ? job.error ?? 'Import failed.'
        : (job.cancelled
            ? 'Cancelling…'
            : 'Copying to this phone · ${_mbOf(job.copiedBytes, job.totalBytes)}');
    return LnCard(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const LnIconTile(LnIcons.document, size: 40, iconSize: 20, radius: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(job.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LnText.rowTitleSmall),
              const SizedBox(height: 2),
              Text(line,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: LnText.meta.copyWith(
                      color: failed ? LnColors.attention : LnColors.ink2)),
            ]),
          ),
          const SizedBox(width: 12),
          LnIconButton(
            icon: LnIcons.x,
            size: 30,
            iconSize: 14,
            color: LnColors.ink2,
            semanticLabel: failed ? 'Dismiss' : 'Cancel import',
            onPressed: job.cancelled ? null : onCancel,
          ),
        ]),
        if (!failed) ...[
          const SizedBox(height: 12),
          _Bar(value: job.fraction),
          const SizedBox(height: 12),
          Text('Next: upload and transcript. You can leave this screen.',
              style: LnText.meta.copyWith(color: LnColors.ink3)),
        ],
      ]),
    );
  }

  static String _mbOf(int done, int total) {
    final t = megabytes(total);
    final unit = t.split(' ').last;
    final div = unit == 'MB' ? 1024 * 1024 : 1024;
    final d = (done / div);
    final ds = unit == 'MB' && total < 10 * 1024 * 1024
        ? d.toStringAsFixed(1)
        : d.floor().toString();
    return '$ds of $t';
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value});
  final double value;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 6,
          child: Stack(children: [
            Container(color: LnColors.fill),
            AnimatedFractionallySizedBox(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              widthFactor: value.clamp(0.0, 1.0),
              child: Container(
                  decoration: BoxDecoration(
                      color: LnColors.ink,
                      borderRadius: BorderRadius.circular(3))),
            ),
          ]),
        ),
      );
}

/// "Recent imports" card (F3): ready notes get a green check and length;
/// others show where they are in the pipeline.
class RecentImports extends StatelessWidget {
  const RecentImports({super.key, required this.notes, this.topGap = 18});
  final List<Recording> notes;
  final double topGap;

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(height: topGap),
      const LnSectionLabel('Recent imports'),
      LnCardGroup(children: [
        for (final n in notes) _RecentRow(note: n),
      ]),
    ]);
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.note});
  final Recording note;

  @override
  Widget build(BuildContext context) {
    final st = note.processingStatus;
    final ready = st == ProcessingStatus.done;
    final String line;
    if (ready) {
      line = 'Ready · ${formatDuration(note.duration)}';
    } else if (st.needsAttention) {
      line = note.processingError ?? 'Needs attention';
    } else if (st.inProgress) {
      final pct = note.progress == null ? '' : ' · ${(note.progress! * 100).round()}%';
      line = '${note.processingProgress ?? 'Waiting to process'}$pct';
    } else {
      line = 'Saved · ${formatDuration(note.duration)}';
    }
    return LnPressable(
      onPressed: () => context.pushOnce(R.note, pathParameters: {'id': note.id}),
      pressedOpacity: 0.7,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LnText.rowTitleSmall),
              const SizedBox(height: 2),
              Row(children: [
                if (ready) ...[
                  const LnIcon(LnIcons.check, size: 12, color: LnColors.saved),
                  const SizedBox(width: 5),
                ],
                Expanded(
                  child: Text(line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LnText.meta.copyWith(
                          color: st.needsAttention
                              ? LnColors.attention
                              : LnColors.ink2)),
                ),
              ]),
            ]),
          ),
          const SizedBox(width: 12),
          const LnIcon(LnIcons.chevronRight, size: 16, color: LnColors.ink3),
        ]),
      ),
    );
  }
}

/// Dashed rounded border (the F1 drop card).
class DashedBorder extends StatelessWidget {
  const DashedBorder({super.key, required this.child, this.radius = 20});
  final Widget child;
  final double radius;
  @override
  Widget build(BuildContext context) => CustomPaint(
        foregroundPainter: _DashPainter(radius),
        child: child,
      );
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.radius);
  final double radius;
  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(0.5), Radius.circular(radius));
    final paint = Paint()
      ..color = LnColors.ink3
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()..addRRect(rrect);
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + 4), paint);
        d += 7;
      }
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.radius != radius;
}
