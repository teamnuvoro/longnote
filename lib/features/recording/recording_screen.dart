import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../core/recording/recording_controller.dart';
import '../../core/util/clock.dart';
import '../../theme.dart';

/// Live recording: timer, level meter, pause/resume, stop, "Saved on this
/// phone" indicator and an honest interruption banner.
class RecordingScreen extends StatelessWidget {
  const RecordingScreen({super.key});

  Future<void> _stop(BuildContext context, RecordingController c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop recording?'),
        content: const Text('The audio is saved. Transcript and summary start right after.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep recording')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Stop')),
        ],
      ),
    );
    if (ok != true) return;
    final rec = await c.stop();
    if (!context.mounted) return;
    final router = GoRouter.of(context);
    router.pop();
    if (rec != null) router.pushNamed(R.note, pathParameters: {'id': rec.id});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecordingController>();
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final paused = c.state == CaptureState.paused;
    final stopping = c.state == CaptureState.stopping;

    // Map dBFS (-60..0) to 0..1.
    final level = ((c.levelDb + 60) / 60).clamp(0.0, 1.0);
    final saved = c.lastSavedAt;
    final savedAgo = saved == null
        ? null
        : DateTime.now().difference(saved).inSeconds;

    // Recording ended on its own (e.g. storage full) while this screen was open.
    if (c.state == CaptureState.idle && c.banner != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Recording stopped')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(c.banner!, style: t.bodyLarge),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to list (keeps recording)',
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(c.current?.title ?? 'Recording', overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (c.banner != null)
              MaterialBanner(
                backgroundColor: cs.tertiaryContainer,
                leading: const Icon(Icons.phone_in_talk_outlined),
                content: Text(c.banner!),
                actions: const [SizedBox.shrink()],
              ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.fiber_manual_record,
                    color: paused ? cs.outline : recordRed, size: 18),
                const SizedBox(width: 8),
                Text(paused ? 'Paused' : 'Recording',
                    style: t.titleMedium?.copyWith(color: paused ? cs.outline : recordRed)),
              ],
            ),
            const SizedBox(height: 12),
            Semantics(
              label: 'Recorded time',
              child: Text(formatDuration(c.elapsed),
                  style: t.displayLarge?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontWeight: FontWeight.w300)),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Semantics(
                label: 'Microphone level',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: paused ? 0 : level,
                    minHeight: 10,
                    color: recordRed,
                    backgroundColor: cs.surfaceContainerHighest,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline, size: 16, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  savedAgo == null
                      ? 'Saved on this phone'
                      : 'Saved on this phone · ${savedAgo <= 1 ? 'just now' : '$savedAgo s ago'}',
                  style: t.bodyMedium?.copyWith(color: cs.primary),
                ),
              ],
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'You can lock the screen; recording continues. If you swipe the app away, recording stops, and everything saved until then is kept.',
                textAlign: TextAlign.center,
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _RoundAction(
                  icon: paused ? Icons.play_arrow : Icons.pause,
                  label: paused ? 'Resume' : 'Pause',
                  onTap: stopping ? null : (paused ? c.resume : c.pause),
                ),
                _RoundAction(
                  icon: Icons.stop,
                  label: 'Stop',
                  big: true,
                  color: recordRed,
                  onTap: stopping ? null : () => _stop(context, c),
                ),
              ],
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction(
      {required this.icon, required this.label, this.onTap, this.big = false, this.color});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool big;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final size = big ? 84.0 : 68.0;
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: Column(
        children: [
          Material(
            color: color ?? cs.surfaceContainerHighest,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: size,
                height: size,
                child: Icon(icon,
                    size: big ? 40 : 32,
                    color: color == null ? cs.onSurface : Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label),
        ],
      ),
    );
  }
}
