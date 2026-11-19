// Simulator QA run 1 (fresh install): onboarding -> paywall -> trial ->
// record ~35 s of a 2-voice meeting (mark moment, pause/resume) -> Stop &
// save -> note-ready sheet "Not now" -> repeated Back/open while processing
// (the TestFlight 105 freezes) -> summary -> transcript (2 speakers) -> tap a
// line seeks -> rename speakers -> Ask + source chip -> share options ->
// search finds a spoken word. Real app, real Supabase backend.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/recording/recording_controller.dart';
import 'package:longnote/core/summary/summary_models.dart';
import 'package:longnote/features/ask/ask_chat_screen.dart';
import 'package:longnote/features/common/note_ready_ask.dart';
import 'package:longnote/features/note/note_screen.dart';
import 'package:longnote/features/note/share_sheet.dart';
import 'package:longnote/features/note/speakers_sheet.dart';
import 'package:longnote/features/note/transcript_view.dart';
import 'package:longnote/features/notes/notes_screen.dart';
import 'package:longnote/features/notes/search_screen.dart';
import 'package:longnote/features/onboarding/onboarding_screen.dart';
import 'package:longnote/features/paywall/paywall_screen.dart';
import 'package:longnote/features/paywall/trial_started_screen.dart';
import 'package:longnote/features/recording/recording_screen.dart';
import 'package:longnote/ui/widgets.dart';

import 'support/file_pcm_source.dart';
import 'support/qa_harness.dart';

void main() {
  qaRunTest('QA run 1: first run and a recorded meeting', (qa) async {
    final t = qa.tester;
    late String noteId;
    late String title;

    // ------------------------------------------------------------ First run
    const first = 'First run';
    await qa.check('A1', 'Fresh install opens on onboarding', () async {
      await qa.launch();
      await qa.expectOnTop<OnboardingScreen>();
    }, section: first);

    await qa.check('A2', 'Onboarding: questions, the pitch pages, Allow microphone -> paywall',
        () async {
      await passOnboardingPages(qa, shots: true);
      await qa.tap(find.text('Allow microphone'));
      await qa.expectOnTop<PaywallScreen>();
    }, section: first, needs: ['A1']);

    await qa.check('A3', 'Paywall shows the trial, prices and charge date', () async {
      final line = t.widget<Text>(find.byKey(const ValueKey('paywall-price-line')));
      final text = line.data ?? line.textSpan?.toPlainText() ?? '';
      qa.note('price line: "$text"');
      expect(text, matches(RegExp(r'\d')), reason: 'price line has no number');
      expect(text, matches(RegExp(r'Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec')),
          reason: 'price line has no date');
      expect(find.text('Start free trial'), findsOneWidget);
    }, section: first, needs: ['A2']);

    await qa.check('A4', 'Start free trial -> "trial is on" -> Skip -> empty Notes', () async {
      await qa.tap(find.text('Start free trial'));
      await qa.expectOnTop<TrialStartedScreen>();
      await qa.shot('trial-started');
      // "Allow the reminder" opens iOS's notification prompt (a system alert
      // a Flutter test cannot answer), so the run takes Skip.
      await qa.tap(find.text('Skip — I’ll remember'));
      await qa.expectOnTop<NotesScreen>();
      await qa.waitFor(find.text('Your first note is one tap away'));
      expect(qa.services.billing.entitlement.value.status, EntitlementStatus.trial);
      expect(find.textContaining('Trial ·'), findsOneWidget);
    }, section: first, needs: ['A2']);

    // ------------------------------------------------------------ Recording
    const rec = 'Recording';
    await qa.check('B1', 'Record -> recording screen; timer and mic level move', () async {
      FilePcmSource.nextPath = Qa.audio('main_2voices.wav');
      await qa.tap(find.text('Record'));
      await qa.tap(find.byKey(const ValueKey('record-start')));
      await qa.expectOnTop<RecordingScreen>();
      final c = qa.services.recorder;
      expect(c.isActive, isTrue, reason: 'recorder not active');
      var loudest = -60.0;
      for (var i = 0; i < 20; i++) {
        await qa.wait(const Duration(milliseconds: 200));
        if (c.level.value > loudest) loudest = c.level.value;
      }
      noteId = c.current!.id;
      title = c.current!.title;
      qa.note('note "$title", ${c.elapsed.inMilliseconds} ms after 4 s, '
          'loudest level ${loudest.toStringAsFixed(1)} dBFS');
      expect(c.elapsed.inMilliseconds, greaterThan(2500));
      expect(loudest, greaterThan(-50.0), reason: 'mic level never moved');
    }, section: rec, needs: ['A4']);

    await qa.check('B2', 'Mark moment', () async {
      await qa.tap(find.text('Mark moment'));
      await qa.waitUntil(() async => (await qa.services.moments.list(noteId)).isNotEmpty,
          what: 'the moment to be saved', timeout: const Duration(seconds: 5));
      final m = await qa.services.moments.list(noteId);
      qa.note('moment at ${m.first.atMs} ms');
    }, section: rec, needs: ['B1']);

    await qa.check('B3', 'Pause stops the timer; Resume continues', () async {
      final c = qa.services.recorder;
      await qa.wait(const Duration(seconds: 3));
      await qa.tap(byLabel('Pause'));
      expect(c.state, CaptureState.paused);
      final atPause = c.elapsed;
      await qa.wait(const Duration(seconds: 3));
      await qa.shot('paused');
      final drift = c.elapsed - atPause;
      qa.note('timer moved ${drift.inMilliseconds} ms during 3 s of pause');
      expect(drift.inMilliseconds, lessThan(400), reason: 'timer ran while paused');
      await qa.tap(byLabel('Resume'));
      expect(c.state, CaptureState.recording);
      final atResume = c.elapsed;
      await qa.wait(const Duration(seconds: 2));
      expect((c.elapsed - atResume).inMilliseconds, greaterThan(1200),
          reason: 'timer did not continue after Resume');
    }, section: rec, needs: ['B1']);

    await qa.check('B4', 'Stop & save -> note screen -> "note ready" sheet -> Not now',
        () async {
      // Play the whole clip (both voices) before stopping.
      await qa.waitUntil(() async => FilePcmSource.current?.finished ?? true,
          what: 'the clip to finish', timeout: const Duration(seconds: 60));
      await qa.wait(const Duration(milliseconds: 500));
      final sw = Stopwatch()..start();
      await qa.tap(byLabel('Stop & save'), after: const Duration(milliseconds: 100));
      await qa.expectOnTop<NoteScreen>(timeout: const Duration(seconds: 5));
      qa.note('note screen after ${sw.elapsedMilliseconds} ms');
      await qa.waitFor(find.byType(NoteReadyAskSheet),
          what: 'the "Tell you when it’s ready?" sheet', timeout: const Duration(seconds: 5));
      await qa.wait(const Duration(milliseconds: 600));
      await qa.shot('note-ready-sheet');
      await qa.tap(find.text('Not now'));
      await qa.waitGone(find.byType(NoteReadyAskSheet));
      await qa.expectOnTop<NoteScreen>();
      final n = (await qa.services.repo.get(noteId))!;
      qa.note('saved ${n.durationMs} ms of audio, status ${n.processingStatus.name}');
      expect(n.durationMs, inInclusiveRange(32000, 40000));
      expect(qa.services.recorder.isActive, isFalse);
    }, section: rec, needs: ['B1']);

    // ------------------------------------------------------------ Processing
    const proc = 'Processing';
    final timeline = <String>[];
    final processingStart = DateTime.now();
    await qa.check('C1', 'Back and re-open the note many times while it processes '
        '(no freeze)', () async {
      var round = 0;
      final atBack = <String>{};
      var slowest = 0;
      while (round < 14) {
        final n = (await qa.services.repo.get(noteId))!;
        if (!n.processingStatus.inProgress) break;
        round++;
        atBack.add(n.processingStatus.name);
        timeline.add('${DateTime.now().difference(processingStart).inSeconds}s '
            '${n.processingStatus.name}');
        var sw = Stopwatch()..start();
        await qa.back();
        await qa.expectOnTop<NotesScreen>(timeout: const Duration(seconds: 4));
        if (sw.elapsedMilliseconds > slowest) slowest = sw.elapsedMilliseconds;
        if (round == 1) await qa.shot('notes-while-processing');
        sw = Stopwatch()..start();
        await qa.tap(find.text(title));
        await qa.expectOnTop<NoteScreen>(timeout: const Duration(seconds: 4));
        if (sw.elapsedMilliseconds > slowest) slowest = sw.elapsedMilliseconds;
        if (n.processingStatus == ProcessingStatus.summarizing) {
          await qa.shot('writing-summary');
        }
        await qa.wait(const Duration(milliseconds: 1200));
      }
      qa.note('$round Back + re-open rounds; statuses at Back: ${atBack.join(', ')}; '
          'slowest screen change $slowest ms');
      expect(round, greaterThan(0), reason: 'the note was done before any Back');
    }, section: proc, needs: ['B4'], timeout: const Duration(minutes: 5));

    await qa.check('C2', 'The note processes to a visible summary', () async {
      final seen = await qa.waitForStatus(noteId, ProcessingStatus.done,
          timeout: const Duration(minutes: 5));
      qa.note('statuses: ${seen.map((s) => s.name).join(' > ')}');
      qa.note('done ${DateTime.now().difference(processingStart).inSeconds} s after Stop');
      if (timeline.isNotEmpty) qa.note('during Back rounds: ${timeline.join(', ')}');
      if (!qa.onTop<NoteScreen>()) await qa.tap(find.text(title));
      final raw = await qa.services.repo.summary(noteId);
      expect(raw, isNotNull, reason: 'no summary saved');
      final s = MeetingSummary.parse(raw!.json);
      final short = (s.inShort ?? '').trim();
      qa.note('in short: "$short"');
      expect(short, isNotEmpty);
      final head = short.length > 30 ? short.substring(0, 30) : short;
      await qa.waitFor(find.textContaining(head), what: 'the summary on screen');
    }, section: proc, needs: ['B4'], timeout: const Duration(minutes: 6));

    // ------------------------------------------------------------ Note
    const note = 'Note';
    await qa.check('D1', 'Transcript tab shows 2 speakers', () async {
      await qa.tap(find.text('Transcript'));
      await qa.waitFor(find.byType(TurnRow), what: 'transcript lines');
      final lines = await qa.services.repo.transcript(noteId);
      final speakers = {for (final l in lines) l.speaker};
      qa.note('${lines.length} lines, speakers ${speakers.join(', ')}');
      qa.note('first line: "${lines.first.text}"');
      expect(speakers.length, greaterThanOrEqualTo(2));
      expect(find.text('Speaker 1'), findsWidgets);
      expect(find.text('Speaker 2'), findsWidgets);
    }, section: note, needs: ['C2']);

    await qa.check('D2', 'Tapping a transcript line moves the player there', () async {
      final rows = byLabelPrefix('Play from ');
      await qa.waitFor(rows);
      final labels = rows
          .evaluate()
          .map((e) => (e.widget as LnPressable).semanticLabel!)
          .toList();
      final pick = labels.length > 1 ? 1 : 0;
      final label = labels[pick];
      final parts = label.substring('Play from '.length).split(':');
      final startMs = (int.parse(parts[0]) * 60 + int.parse(parts[1])) * 1000;
      await qa.tap(byLabel(label), after: const Duration(milliseconds: 1500));
      final player = find.byType(LnMiniPlayer);
      await qa.waitFor(player, what: 'the mini player');
      int readPos() =>
          t.widget<LnMiniPlayer>(player.last).position.inMilliseconds;
      // A slow CI machine can finish the seek after the first read (18 Nov:
      // read 0 ms while the screenshot showed 0:08), so wait for it.
      try {
        await qa.waitUntil(() async => readPos() >= startMs - 1000,
            timeout: const Duration(seconds: 6), what: 'the player to seek');
      } catch (_) {/* the expect below reports the real value */}
      final pos = readPos();
      qa.note('tapped "$label" -> player at $pos ms');
      expect(pos, inInclusiveRange(startMs - 1000, startMs + 4000));
      // Stop playback before going on.
      final pause = byLabel('Pause');
      if (pause.hitTestable().evaluate().isNotEmpty) await qa.tap(pause);
    }, section: note, needs: ['D1']);

    await qa.check('D3', 'Edit names: rename both speakers', () async {
      await qa.tap(find.text('Edit names'));
      await qa.expectOnTop<SpeakersSheet>();
      final fields = find.descendant(
          of: find.byType(SpeakersSheet), matching: find.byType(TextField));
      await qa.waitFor(fields);
      await t.enterText(fields.at(0), 'Asha');
      await t.enterText(fields.at(1), 'Ravi');
      await qa.wait(const Duration(milliseconds: 300));
      await qa.tap(find.text('Save'));
      await qa.expectOnTop<NoteScreen>();
      await qa.waitFor(find.text('Asha'));
      expect(find.text('Ravi'), findsWidgets);
      // A slow machine may still be rebuilding the transcript rows.
      await qa.waitUntil(() async => find.text('Speaker 1').evaluate().isEmpty,
          what: 'every "Speaker 1" label to be renamed',
          timeout: const Duration(seconds: 10));
    }, section: note, needs: ['D1']);

    await qa.check('D4', 'Ask a question -> answer with a source -> source opens the '
        'transcript there', () async {
      await qa.tap(find.text('Ask'));
      await qa.expectOnTop<AskChatScreen>();
      // The box is disabled until the screen has loaded its note.
      final input = find.byKey(const ValueKey('ask-input'));
      await qa.waitUntil(() async =>
              input.evaluate().isNotEmpty && t.widget<TextField>(input).enabled != false,
          what: 'the question box to be ready', timeout: const Duration(seconds: 20));
      const q = 'When will the description and the privacy answers be finished?';
      await qa.type(input, q);
      expect(t.widget<TextField>(input).controller?.text, q,
          reason: 'the question did not reach the box');
      await qa.tap(find.byKey(const ValueKey('ask-send')));
      final chip = byLabelPrefix('Open the transcript at');
      await qa.waitFor(chip, what: 'an answer with a source chip',
          timeout: const Duration(seconds: 90));
      final msgs = await qa.services.chat.list(noteId);
      if (msgs.isNotEmpty) qa.note('answer: "${msgs.last.text}"');
      final chipLabel = (chip.evaluate().first.widget as LnPressable).semanticLabel;
      qa.note('source chip: $chipLabel');
      await qa.shot('answer');
      await qa.tap(chip);
      await qa.expectOnTop<NoteScreen>();
      await qa.waitFor(find.byWidgetPredicate((w) => w is TurnRow && w.highlighted),
          what: 'the source line highlighted');
      await qa.shot('source-line');
      await qa.back();
      await qa.expectOnTop<AskChatScreen>();
      await qa.back();
      await qa.expectOnTop<NoteScreen>();
    }, section: note, needs: ['C2'], timeout: const Duration(minutes: 3));

    // A failed check may leave Ask or a sheet open: back to the note.
    Future<void> backToNote() async {
      for (var i = 0; i < 4 && !qa.onTop<NoteScreen>(); i++) {
        await qa.back();
      }
      await qa.expectOnTop<NoteScreen>();
    }

    final share = ShareRecorder()..install(t);
    await qa.check('D5', 'Share: PDF, summary, transcript, audio (M4A and WAV), copy',
        () async {
      await backToNote();
      await qa.tap(byLabel('Share'));
      await qa.expectOnTop<ShareSheet>();
      Future<void> option(String what, {String? then}) async {
        final before = share.calls.length;
        await qa.tap(find.text(what));
        if (then != null) await qa.tap(find.text(then));
        await qa.waitUntil(() async => share.calls.length > before,
            what: '"$what" to reach the iOS share sheet',
            timeout: const Duration(seconds: 90));
        await qa.wait(const Duration(milliseconds: 500));
        expect(find.text('Could not share this. Please try again.'), findsNothing);
        qa.note('$what${then == null ? '' : ' / $then'}: ${share.calls.last}');
      }

      await option('PDF');
      final pdf = (share.calls.last['files'] as List).single as Map;
      expect(pdf['bytes'] as int, greaterThan(2000), reason: 'PDF too small');
      await option('Summary');
      expect(share.calls.last['text_chars'] as int, greaterThan(40));
      await option('Transcript');
      expect(share.calls.last['text_chars'] as int, greaterThan(40));
      await option('Audio file', then: 'M4A · smaller');
      final m4a = (share.calls.last['files'] as List).single as Map;
      expect(m4a['bytes'] as int, greaterThan(20000), reason: 'M4A too small');
      await option('Audio file', then: 'WAV · original quality');
      final wav = (share.calls.last['files'] as List).single as Map;
      expect(wav['bytes'] as int, greaterThan(32000 * 30), reason: 'WAV too small');
      await qa.tap(byLabel('Copy summary'));
      final clip = await Clipboard.getData('text/plain');
      qa.note('copied ${clip?.text?.length ?? 0} characters');
      expect(clip?.text ?? '', isNotEmpty);
      await qa.tap(find.text('Done'));
      await qa.expectOnTop<NoteScreen>();
    }, section: note, needs: ['C2']);
    share.uninstall(t);

    await qa.check('D6', 'Back to Notes: the note is listed', () async {
      await backToNote();
      await qa.back();
      await qa.expectOnTop<NotesScreen>();
      await qa.waitFor(find.text(title));
    }, section: note, needs: ['C2']);

    await qa.check('D7', 'Search finds a word that was said ("screenshots")', () async {
      await qa.tap(find.byType(LnSearchField));
      await qa.expectOnTop<SearchScreen>();
      await qa.type(find.descendant(
          of: find.byType(SearchScreen), matching: find.byType(TextField)), 'screenshots');
      await qa.waitFor(
          find.descendant(of: find.byType(SearchScreen), matching: find.text(title)),
          what: 'the note in the results');
      await qa.shot('results');
      await qa.tap(byLabel('Cancel'));
      await qa.expectOnTop<NotesScreen>();
    }, section: note, needs: ['D6']);
  });
}
