import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../app/nav.dart';
import '../../app_services.dart';
import '../../core/notes/languages.dart';
import '../../core/recording/recording_controller.dart';
import '../../core/recording/recording_repository.dart';
import '../../ui/widgets.dart';
import '../note/kit.dart';

/// Recent input levels per recording, so the waveform survives minimising
/// the screen (and tests can seed it).
abstract final class RecordingLevels {
  static final history = <String, List<double>>{};
  static const max = 160;

  static List<double> of(String id) {
    if (!history.containsKey(id)) history.clear(); // one recording at a time
    return history.putIfAbsent(id, () => <double>[]);
  }
}

/// C1 live · C2 paused · C3 phone call (Figma 6:191, 6:322, 6:448): the dark
/// "focus" screen. Minimise (chevron) goes back to Notes while recording
/// continues. Capture itself is the crash-safe [RecordingController].
///
/// With [ready] (the Record button on Notes) it opens before anything
/// records: the user taps Start to begin, or closes it and nothing is kept.
class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key, this.ready = false});

  /// Route query parameter (`/record?ready=1`) for [ready].
  static const readyParam = 'ready';

  /// Open in the "ready" state: no recording yet, one Start button.
  final bool ready;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  late final AppServices _s = context.read<AppServices>();
  late final RecordingRepository _repo = context.read<RecordingRepository>();
  String? _language;
  String? _title;
  String? _lastId;
  bool _busy = false;

  /// Waiting for the user to tap Start (until a recording has started).
  late bool _ready = widget.ready && !_s.recorder.isActive;
  bool _starting = false;

  /// When Start succeeded. Pause sits where Start was, so a fast double tap
  /// on Start must not pause straight away.
  DateTime? _startedAt;
  static const _startTapGuard = Duration(milliseconds: 600);

  void _pauseOrResume(RecordingController c, bool paused) {
    if (paused) {
      c.resume();
      return;
    }
    final at = _startedAt;
    if (at != null && clock.now().difference(at) < _startTapGuard) return;
    c.pause();
  }

  @override
  void initState() {
    super.initState();
    _repo.addListener(_loadNote);
    _loadNote();
  }

  @override
  void dispose() {
    _repo.removeListener(_loadNote);
    super.dispose();
  }

  Future<void> _loadNote() async {
    final id = _s.recorder.current?.id ?? _lastId;
    if (id == null) return;
    _lastId = id;
    final n = await _repo.get(id);
    if (!mounted || n == null) return;
    if (n.language != _language || n.title != _title) {
      setState(() {
        _language = n.language;
        _title = n.title;
      });
    }
  }

  /// Start (ready state). Stays on the ready screen with a toast on failure.
  Future<void> _start() async {
    if (_starting || !_ready) return;
    setState(() => _starting = true);
    try {
      await _s.startRecording();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        // Normally nothing started; if capture did start, show it live.
        _ready = !_s.recorder.isActive;
      });
      showToast(
          context,
          e.toString().contains('permission')
              ? 'Microphone is off. Turn it on in iPhone Settings › Longnote.'
              : 'Could not start recording. Please try again.');
      return;
    }
    if (!mounted) return;
    _startedAt = clock.now();
    setState(() {
      _starting = false;
      _ready = false;
    });
    unawaited(_loadNote());
  }

  void _minimise() =>
      context.canPop() ? context.pop() : context.goNamed(R.notes);

  /// Set when the user stops or discards: this screen is about to close, so
  /// it must not show the "recording has ended" card meanwhile.
  bool _leaving = false;

  Future<void> _stop(RecordingController c) async {
    if (_busy) return;
    _busy = true;
    _leaving = true;
    final router = GoRouter.of(context);
    final rec = await c.stop();
    _busy = false;
    if (!mounted) return;
    if (rec == null) {
      // Could not save the ending (disk full): show the card with the
      // explanation instead of leaving silently.
      setState(() => _leaving = false);
      return;
    }
    if (router.canPop()) router.pop();
    router.pushNamed(R.note, pathParameters: {'id': rec.id});
  }

  Future<void> _discard() async {
    final ok = await context.pushOnce<bool>(R.discard);
    if (ok != true || !mounted) return;
    setState(() => _leaving = true);
    final router = GoRouter.of(context);
    await _s.discardRecording();
    if (mounted && router.canPop()) router.pop();
  }

  Future<void> _rename(RecordingController c) async {
    final rec = c.current;
    if (rec == null) return;
    final name = await askForText(context,
        title: 'Name this note', initial: _title ?? rec.title);
    if (name == null) return;
    rec.title = name;
    await _repo.rename(rec.id, name);
  }

  Future<void> _mark(RecordingController c) async {
    final rec = c.current;
    if (rec == null) return;
    final at = c.elapsed.inMilliseconds;
    await _s.moments.add(rec.id, at);
    if (mounted) showToast(context, 'Moment marked at ${clockText(at)}');
  }

  Future<void> _chooseLanguage(RecordingController c) async {
    final rec = c.current;
    if (rec == null) return;
    final code = await showLnSheet<String>(
      context,
      builder: (_) => LanguageSheet(selected: _language ?? 'auto'),
    );
    if (code == null) return;
    await _repo.setNoteOptions(rec.id, language: code);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecordingController>();
    final bottom = MediaQuery.paddingOf(context).bottom;

    if (_ready && (c.state == CaptureState.idle || c.state == CaptureState.starting)) {
      return _Ready(
        starting: _starting || c.state == CaptureState.starting,
        onStart: _start,
        onClose: _minimise,
      );
    }
    if (_leaving && c.state == CaptureState.idle) {
      return const Scaffold(backgroundColor: LnColors.night);
    }
    // Ended on its own (e.g. storage full) while this screen was open.
    if (c.state == CaptureState.idle) {
      return _Ended(
        message: c.banner ?? 'The recording has ended. Everything up to now is saved.',
        noteId: _lastId,
      );
    }

    final paused = c.state == CaptureState.paused;
    final banner = c.banner;
    final call = paused && banner != null && banner.startsWith('Paused by');
    final elapsed = c.elapsed;
    final rec = c.current;
    final started = rec?.createdAt;
    final saved = c.lastSavedAt != null;
    final stopping = c.state == CaptureState.stopping;

    Widget info;
    if (call) {
      info = _CallBanner(
        title: 'Paused for a phone call',
        body:
            'Everything up to ${timerText(elapsed)} is saved. Recording resumes on its own when the call ends; the gap is marked in your note.',
      );
    } else if (paused && banner != null) {
      info = _CallBanner(title: 'Paused', body: banner);
    } else if (paused) {
      info = SizedBox(
        width: 300,
        child: Text(
            'Paused at ${timerText(elapsed)}. Nothing is recorded until you resume.',
            textAlign: TextAlign.center,
            style: LnText.meta.copyWith(color: LnColors.nightText3)),
      );
    } else if (banner != null) {
      info = _CallBanner(title: 'Recording', body: banner);
    } else {
      info = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        const LnIcon(LnIcons.lock, size: 14, color: LnColors.nightText3),
        const SizedBox(width: 8),
        Text('You can lock your phone. Recording continues.',
            style: LnText.meta.copyWith(color: LnColors.nightText3)),
      ]);
    }

    return Scaffold(
      backgroundColor: LnColors.night,
      body: SafeArea(
        bottom: false,
        // Scrolls only on short phones; on a 393 x 852 screen it fits.
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: IntrinsicHeight(child: Column(children: [
          const SizedBox(height: 4),
          // Top bar: minimise, status, saved.
          SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
              child: Stack(alignment: Alignment.center, children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: LnIconButton(
                    icon: LnIcons.chevronDown,
                    background: LnColors.nightFill,
                    color: LnColors.nightText,
                    semanticLabel: 'Back to notes (keeps recording)',
                    onPressed: _minimise,
                  ),
                ),
                LnStatusPill(paused ? LnStatus.paused : LnStatus.recording,
                    label: call ? 'Paused for a call' : null),
                if (saved)
                  const Align(
                      alignment: Alignment.centerRight,
                      child: LnStatusPill(LnStatus.saved)),
              ]),
            ),
          ),
          const SizedBox(height: 38),
          LnPressable(
            onPressed: () => _rename(c),
            semanticLabel: 'Rename',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Flexible(
                  child: Text(_title ?? rec?.title ?? 'Recording',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LnText.recordingTitle),
                ),
                const SizedBox(width: 8),
                const LnIcon(LnIcons.pencil, size: 15, color: LnColors.nightText3),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          if (started != null)
            Text('${shortDate(started)} · started ${timeOfDay(started)}',
                style: LnText.meta.copyWith(color: LnColors.nightText3)),
          const SizedBox(height: 57),
          SizedBox(
            height: 78,
            child: Center(
              child: Semantics(
                label: 'Recorded time',
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  style: LnText.timer.copyWith(
                      color: paused ? LnColors.nightText3 : LnColors.nightText,
                      fontFeatures: const [FontFeature.tabularFigures()]),
                  child: Text(timerText(elapsed)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            height: 120,
            child: _LiveWaveform(controller: c, paused: paused),
          ),
          const SizedBox(height: 28),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            LnPillChip(
              dark: true,
              icon: LnIcons.globe,
              label: _language == null || _language == 'auto'
                  ? 'Auto-detect'
                  : audioLanguageFor(_language).name,
              onTap: () => _chooseLanguage(c),
            ),
            const SizedBox(width: 8),
            LnPillChip(
              dark: true,
              icon: LnIcons.bookmark,
              label: 'Mark moment',
              onTap: () => _mark(c),
            ),
          ]),
          SizedBox(height: call || (paused && banner != null) ? 27 : 37),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
            child: info,
          ),
          const Spacer(),
          // Controls: Discard · Pause/Resume (big, middle) · Stop & save.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RoundButton(
                label: 'Discard',
                background: LnColors.nightFill,
                onTap: stopping ? null : _discard,
                child: const LnIcon(LnIcons.x, size: 22.8, color: LnColors.nightText),
              ),
              const SizedBox(width: 44),
              _RoundButton(
                label: paused ? (call ? 'Resume now' : 'Resume') : 'Pause',
                size: 84,
                background: paused ? LnColors.signal : LnColors.nightFill,
                strongLabel: true,
                onTap: stopping ? null : () => _pauseOrResume(c, paused),
                child: LnIcon(paused ? LnIcons.play : LnIcons.pause,
                    size: 32, color: LnColors.nightText),
              ),
              const SizedBox(width: 44),
              _RoundButton(
                label: 'Stop & save',
                background: LnColors.card,
                onTap: stopping ? null : () => _stop(c),
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                      color: LnColors.signal, borderRadius: BorderRadius.circular(4)),
                ),
              ),
            ],
          ),
          SizedBox(height: (call ? 16 : 30) + bottom),
        ])),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.label,
    required this.background,
    required this.child,
    this.onTap,
    this.size = 60,
    this.width = 84,
    this.strongLabel = false,
  });
  final String label;
  final Color background;
  final Widget child;
  final VoidCallback? onTap;
  final double size;
  final double width;
  final bool strongLabel;

  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        semanticLabel: label,
        pressedOpacity: 0.7,
        child: SizedBox(
          width: width,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: background, shape: BoxShape.circle),
              child: child,
            ),
            const SizedBox(height: 8),
            Text(label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: strongLabel
                    ? LnText.smallButton.copyWith(
                        fontSize: 12, color: LnColors.nightText)
                    : LnText.chip.copyWith(color: LnColors.nightText3)),
          ]),
        ),
      );
}

/// Amber banner (C3 "Paused for a phone call").
class _CallBanner extends StatelessWidget {
  const _CallBanner({required this.title, required this.body});
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2214),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF5A4318)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const LnIcon(LnIcons.phone, size: 18, color: LnColors.pausedPillText),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: LnText.smallButton
                      .copyWith(fontSize: 14, color: LnColors.pausedPillText)),
              const SizedBox(height: 2),
              Text(body,
                  style: LnText.meta.copyWith(
                      height: 18 / 13, color: const Color(0xFFD8C7A6))),
            ]),
          ),
        ]),
      );
}

/// Live waveform from the real input level (dBFS), newest bar at the red
/// line, dotted "still to come" on the right. Bars are 3 px every 6 px.
class _LiveWaveform extends StatefulWidget {
  const _LiveWaveform({required this.controller, required this.paused});
  final RecordingController controller;
  final bool paused;
  @override
  State<_LiveWaveform> createState() => _LiveWaveformState();
}

class _LiveWaveformState extends State<_LiveWaveform> {
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  double _peak = -60;
  final _repaint = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    widget.controller.level.addListener(_onTick);
  }

  @override
  void didUpdateWidget(covariant _LiveWaveform old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.level.removeListener(_onTick);
      widget.controller.level.addListener(_onTick);
    }
  }

  @override
  void dispose() {
    widget.controller.level.removeListener(_onTick);
    _repaint.dispose();
    super.dispose();
  }

  void _onTick() {
    final c = widget.controller;
    final id = c.current?.id;
    if (id == null || c.state != CaptureState.recording) return;
    if (c.levelDb > _peak) _peak = c.levelDb;
    final now = DateTime.now();
    if (now.difference(_last).inMilliseconds < 110) return;
    _last = now;
    final v = ((_peak + 60) / 60).clamp(0.0, 1.0);
    _peak = -60;
    final h = RecordingLevels.of(id)..add(v);
    if (h.length > RecordingLevels.max) h.removeRange(0, h.length - RecordingLevels.max);
    _repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.controller.current?.id;
    return Semantics(
      label: 'Microphone level',
      child: CustomPaint(
        size: const Size(double.infinity, 120),
        painter: _WavePainter(
          levels: id == null ? const [] : RecordingLevels.of(id),
          paused: widget.paused,
          repaint: _repaint,
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.levels, required this.paused, required Listenable repaint})
      : super(repaint: repaint);
  final List<double> levels;
  final bool paused;

  static const _dot = Color(0xFF3A3D46);

  @override
  void paint(Canvas canvas, Size size) {
    const step = 6.0, barW = 3.0;
    final head = (size.width * 0.623).roundToDouble(); // Figma: x 245 of 393
    final mid = size.height / 2;
    final bar = Paint()..color = paused ? LnColors.nightText3 : LnColors.nightText;
    var x = head - step;
    for (var i = levels.length - 1; i >= 0 && x >= 0; i--, x -= step) {
      final v = levels[i];
      // Perceptual curve so speech fills the height.
      final h = (4 + 100 * v * v).clamp(4.0, 104.0);
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(x, mid - h / 2, barW, h), const Radius.circular(1.5)),
          bar);
    }
    final dot = Paint()..color = _dot;
    for (var dx = head + 2.5; dx < size.width; dx += step) {
      canvas.drawCircle(Offset(dx + 1.5, mid), 1.5, dot);
    }
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(head - 1, 4, 2, size.height - 8),
            const Radius.circular(1)),
        Paint()..color = LnColors.signal);
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.paused != paused || old.levels != levels;
}

/// Before anything records (Record on Notes): close, or one big Start.
class _Ready extends StatelessWidget {
  const _Ready({required this.starting, required this.onStart, required this.onClose});
  final bool starting;
  final VoidCallback onStart;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: LnColors.night,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          const SizedBox(height: 4),
          SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
              child: Align(
                alignment: Alignment.centerLeft,
                child: LnIconButton(
                  icon: LnIcons.chevronDown,
                  background: LnColors.nightFill,
                  color: LnColors.nightText,
                  semanticLabel: 'Close (nothing is recorded)',
                  onPressed: starting ? null : onClose,
                ),
              ),
            ),
          ),
          const SizedBox(height: 38),
          Text('New recording', style: LnText.recordingTitle),
          const Spacer(),
          Semantics(
            label: 'Recorded time',
            child: Text(timerText(Duration.zero),
                style: LnText.timer.copyWith(
                    color: LnColors.nightText3,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
          const SizedBox(height: 16),
          Text(starting ? 'Starting…' : 'Tap Start when you’re ready.',
              textAlign: TextAlign.center,
              style: LnText.meta.copyWith(color: LnColors.nightText3)),
          const Spacer(),
          _RoundButton(
            key: const ValueKey('record-start'),
            label: 'Start recording',
            size: 84,
            width: 160,
            background: LnColors.signal,
            strongLabel: true,
            onTap: starting ? null : onStart,
            child: starting
                ? const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: LnColors.nightText))
                : const LnIcon(LnIcons.mic, size: 38, color: LnColors.nightText),
          ),
          SizedBox(height: 30 + bottom),
        ]),
      ),
    );
  }
}

/// Shown when capture ended on its own (mic error, storage full).
class _Ended extends StatelessWidget {
  const _Ended({required this.message, this.noteId});
  final String message;
  final String? noteId;
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: LnColors.night,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(LnSpace.page),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Spacer(),
              Text('Recording stopped',
                  textAlign: TextAlign.center, style: LnText.recordingTitle),
              const SizedBox(height: 12),
              Text(message,
                  textAlign: TextAlign.center,
                  style: LnText.body.copyWith(color: LnColors.nightText2)),
              const Spacer(),
              if (noteId != null) ...[
                LnPrimaryButton(
                  label: 'Open the note',
                  onPressed: () {
                    final router = GoRouter.of(context);
                    if (router.canPop()) router.pop();
                    router.pushNamed(R.note, pathParameters: {'id': noteId!});
                  },
                ),
                const SizedBox(height: 10),
              ],
              LnSecondaryButton(
                label: 'Back to notes',
                onPressed: () =>
                    context.canPop() ? context.pop() : context.goNamed(R.notes),
              ),
            ]),
          ),
        ),
      );
}

/// Language for this recording (C1 chip): auto-detect or one of 60+.
class LanguageSheet extends StatelessWidget {
  const LanguageSheet({super.key, required this.selected});
  final String selected;

  @override
  Widget build(BuildContext context) {
    final items = [autoDetect, ...audioLanguages];
    final h = MediaQuery.sizeOf(context).height * 0.7;
    return LnSheet(
      title: 'Audio language',
      subtitle: 'Used for this recording’s transcript.',
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SizedBox(
        height: h,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: LnColors.card,
            borderRadius: BorderRadius.circular(LnRadius.card),
            border: Border.all(color: LnColors.line),
          ),
          child: ListView.separated(
            padding: EdgeInsets.zero,
            itemCount: items.length,
            separatorBuilder: (_, _) => const Padding(
                padding: EdgeInsets.only(left: 16), child: LnHairline()),
            itemBuilder: (context, i) {
              final l = items[i];
              return LnListRow(
                label: l.name,
                value: l.nativeName,
                showChevron: false,
                trailing: l.code == selected
                    ? const LnIcon(LnIcons.check, size: 18)
                    : null,
                onTap: () => Navigator.of(context).pop(l.code),
              );
            },
          ),
        ),
      ),
    );
  }
}
