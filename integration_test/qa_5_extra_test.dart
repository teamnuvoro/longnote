// Simulator QA run 5 (extra): the iPhone-list items that can be imitated on a
// simulator.
//   K  Phone call: the file microphone sends the same "interruption began /
//      ended" the iOS audio session sends for a call (resumable and not).
//   L  Background: the host opens the Settings app for 10 min while the app
//      records, then brings the app back (stands in for "lock the phone").
//   M  Long recording: 60 min of audio fed at 12x real time through the real
//      recorder, compression, upload, transcription, summary and Ask.
// Not imitated: a real call/lock screen on a device (the real iOS microphone
// and audio session), battery and heat. Those stay on the iPhone list.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/recording/recording_controller.dart';
import 'package:longnote/core/summary/summary_models.dart';
import 'package:longnote/features/ask/ask_chat_screen.dart';
import 'package:longnote/features/common/note_ready_ask.dart';
import 'package:longnote/features/note/note_screen.dart';
import 'package:longnote/features/note/transcript_view.dart';
import 'package:longnote/features/notes/notes_screen.dart';
import 'package:longnote/features/recording/recording_screen.dart';
import 'package:longnote/ui/widgets.dart';

import 'support/file_pcm_source.dart';
import 'support/qa_harness.dart';

String mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(0)} MB';

void main() {
  qaRunTest('QA run 5: phone call, background, 1-hour recording', (qa) async {
    final t = qa.tester;
    RecordingController c() => qa.services.recorder;

    Future<Recording> stopAndSave() async {
      await qa.tap(byLabel('Stop & save'), after: const Duration(milliseconds: 100));
      await qa.expectOnTop<NoteScreen>(timeout: const Duration(seconds: 15));
      await qa.wait(const Duration(seconds: 1));
      if (find.byType(NoteReadyAskSheet).evaluate().isNotEmpty) {
        await qa.tap(find.text('Not now'));
        await qa.waitGone(find.byType(NoteReadyAskSheet));
      }
      return qa.newestNote();
    }

    Future<void> startRecording(String wav) async {
      // A failed check before may have left a recording running: save it.
      if (c().isActive && qa.onTop<RecordingScreen>()) await stopAndSave();
      FilePcmSource.nextPath = Qa.audio(wav);
      if (!qa.onTop<NotesScreen>()) await qa.home();
      await qa.tap(find.text('Record'));
      await qa.tap(find.byKey(const ValueKey('record-start')));
      await qa.expectOnTop<RecordingScreen>();
      await qa.waitUntil(() async => c().state == CaptureState.recording,
          what: 'recording to start', timeout: const Duration(seconds: 10));
    }

    Future<void> expectSummary(String id) async {
      final raw = await qa.services.repo.summary(id);
      expect(raw, isNotNull, reason: 'no summary saved');
      final s = MeetingSummary.parse(raw!.json);
      final short = (s.inShort ?? '').trim();
      qa.note('in short: "${short.length > 200 ? '${short.substring(0, 200)}…' : short}"');
      expect(short, isNotEmpty);
      final head = short.length > 30 ? short.substring(0, 30) : short;
      await qa.waitFor(find.textContaining(head), what: 'the summary on screen');
    }

    await qa.check('K0', 'App opens on Notes', () async {
      await qa.launch();
      await passFirstRunIfShown(qa);
      await qa.expectOnTop<NotesScreen>();
    }, section: 'Start');

    // ------------------------------------------------------------ Phone call
    const call = 'Phone call (simulated)';
    late Recording callNote;
    await qa.check('K1', 'A call comes in: "Paused for a phone call", the timer stops; '
        'the call ends: recording resumes by itself and says what was missed', () async {
      await startRecording('main_2voices.wav');
      await qa.wait(const Duration(seconds: 8));
      FilePcmSource.current!.interruptBegin();
      await qa.waitFor(find.text('Paused for a phone call'),
          what: 'the phone call banner', timeout: const Duration(seconds: 5));
      expect(c().state, CaptureState.paused);
      final atCall = c().elapsed;
      await qa.wait(const Duration(seconds: 6));
      await qa.shot('call-paused');
      expect((c().elapsed - atCall).inMilliseconds, lessThan(400),
          reason: 'timer ran during the call');
      FilePcmSource.current!.interruptEnd(resumable: true);
      await qa.waitUntil(() async => c().state == CaptureState.recording,
          what: 'recording to resume by itself', timeout: const Duration(seconds: 5));
      await qa.waitFor(find.textContaining('was not recorded'),
          what: 'the "was not recorded" line');
      qa.note('banner: "${c().banner}"');
      final atResume = c().elapsed;
      await qa.wait(const Duration(seconds: 2));
      await qa.shot('call-resumed');
      expect((c().elapsed - atResume).inMilliseconds, greaterThan(1200),
          reason: 'timer did not continue after the call');
    }, section: call, needs: ['K0'], timeout: const Duration(minutes: 2));

    await qa.check('K2', 'A call iOS does not let us resume after: "Tap Resume"; '
        'Resume continues', () async {
      FilePcmSource.current!.interruptBegin();
      await qa.waitFor(find.text('Paused for a phone call'));
      await qa.wait(const Duration(seconds: 3));
      FilePcmSource.current!.interruptEnd(resumable: false);
      await qa.waitFor(find.textContaining('Tap Resume to continue'),
          what: 'the "Tap Resume" line');
      expect(c().state, CaptureState.paused);
      await qa.shot('call-not-resumable');
      await qa.tap(byLabel('Resume'));
      await qa.waitUntil(() async => c().state == CaptureState.recording,
          what: 'recording after Resume', timeout: const Duration(seconds: 5));
      final at = c().elapsed;
      await qa.wait(const Duration(seconds: 2));
      expect((c().elapsed - at).inMilliseconds, greaterThan(1200));
    }, section: call, needs: ['K1'], timeout: const Duration(minutes: 2));

    await qa.check('K3', 'Stop & save: the note processes and the transcript shows '
        '"Paused … for a phone call"', () async {
      await qa.waitUntil(() async => FilePcmSource.current?.finished ?? true,
          what: 'the clip to finish', timeout: const Duration(seconds: 60));
      callNote = await stopAndSave();
      final gaps = await qa.services.repo.gaps(callNote.id);
      qa.note('gaps: ${gaps.map((g) => '${g.reason} at ${g.atMs} ms, '
          '${g.endedAt == null ? 'open' : '${g.endedAt!.difference(g.startedAt).inSeconds} s'}').join('; ')}');
      expect(gaps.where((g) => g.endedAt != null), isNotEmpty,
          reason: 'no finished gap saved');
      final seen = await qa.waitForStatus(callNote.id, ProcessingStatus.done,
          timeout: const Duration(minutes: 5));
      qa.note('statuses: ${seen.map((s) => s.name).join(' > ')}');
      await expectSummary(callNote.id);
      await qa.tap(find.text('Transcript'));
      await qa.waitFor(find.byType(TurnRow), what: 'transcript lines');
      await qa.waitFor(find.byType(GapMarker), what: 'the call gap in the transcript');
      final marker = t.widget<Text>(find.descendant(
          of: find.byType(GapMarker).first, matching: find.byType(Text)));
      qa.note('marker: "${marker.data}"');
      expect(marker.data, contains('phone call'));
      await qa.shot('call-gap-in-transcript');
      await qa.back();
    }, section: call, needs: ['K2'], timeout: const Duration(minutes: 7));

    // ------------------------------------------------------------ Background
    const bg = 'App in the background while recording';
    late Recording bgNote;
    await qa.check('L1', 'Recording, the app goes to the background for 10 min (Settings '
        'app on top) and comes back: still recording, the note is not marked '
        'interrupted, the timer covers the 10 min', () async {
      await startRecording('main_2voices.wav');
      await qa.wait(const Duration(seconds: 5));
      final before = c().elapsed;
      final id = c().current!.id;
      final sw = Stopwatch()..start();
      await qa.hostRequest('background-600', timeout: const Duration(minutes: 13));
      await qa.wait(const Duration(seconds: 3));
      final away = sw.elapsed;
      await qa.shot('back-from-background');
      await qa.expectOnTop<RecordingScreen>();
      expect(c().state, CaptureState.recording, reason: 'not recording after coming back');
      final gained = c().elapsed - before;
      qa.note('away ${away.inSeconds} s; timer gained ${gained.inSeconds} s');
      final n = (await qa.services.repo.get(id))!;
      qa.note('note status while recording: ${n.status.name}');
      expect(n.status, RecordingStatus.recording);
      expect(gained.inSeconds, greaterThan(away.inSeconds - 15),
          reason: 'the timer lost time in the background');
    }, section: bg, needs: ['K0'], timeout: const Duration(minutes: 15));

    await qa.check('L2', 'Stop & save: the ~10 min note processes to a summary', () async {
      bgNote = await stopAndSave();
      qa.note('saved ${bgNote.durationMs ~/ 1000} s of audio');
      expect(bgNote.durationMs, greaterThan(590 * 1000));
      final sw = Stopwatch()..start();
      final seen = await qa.waitForStatus(bgNote.id, ProcessingStatus.done,
          timeout: const Duration(minutes: 8));
      qa.note('done in ${sw.elapsed.inSeconds} s; statuses: '
          '${seen.map((s) => s.name).join(' > ')}');
      await expectSummary(bgNote.id);
      await qa.shot('background-note');
      await qa.back();
    }, section: bg, needs: ['L1'], timeout: const Duration(minutes: 10));

    // ------------------------------------------------------------ Long recording
    const long = '1-hour recording (fed at 12x)';
    late Recording longNote;
    await qa.check('M1', 'Record 60 min of audio: the timer reaches 1 hour, the app '
        'stays responsive, memory stays flat', () async {
      FilePcmSource.speed = 12;
      await startRecording('long_60min.wav');
      // After start: the file microphone holds the whole 115 MB WAV in memory.
      final rssStart = ProcessInfo.currentRss;
      var peak = rssStart;
      var slowestTap = 0;
      var i = 0;
      while (!(FilePcmSource.current?.finished ?? true)) {
        await qa.wait(const Duration(seconds: 15));
        final rss = ProcessInfo.currentRss;
        if (rss > peak) peak = rss;
        // Prove the screen still reacts: Mark moment every minute.
        if (++i % 4 == 0) {
          final sw = Stopwatch()..start();
          await qa.tap(find.text('Mark moment'));
          if (sw.elapsedMilliseconds > slowestTap) slowestTap = sw.elapsedMilliseconds;
        }
        if (i == 10) await qa.shot('long-recording-mid');
      }
      await qa.wait(const Duration(seconds: 1));
      await qa.shot('long-recording-end');
      final el = c().elapsed;
      qa.note('timer ${el.inMinutes} min ${el.inSeconds % 60} s; memory '
          '${mb(rssStart)} at start, peak ${mb(peak)}; slowest Mark moment tap '
          '$slowestTap ms');
      expect(el.inMinutes, greaterThanOrEqualTo(59));
      expect(peak - rssStart, lessThan(400 * 1048576),
          reason: 'memory grew a lot while recording');
      FilePcmSource.speed = 1;
    }, section: long, needs: ['K0'], timeout: const Duration(minutes: 12));

    await qa.check('M2', 'Stop & save a 60 min note: compress, upload, transcribe, '
        'summarize (time logged)', () async {
      FilePcmSource.speed = 1;
      final sw = Stopwatch()..start();
      longNote = await stopAndSave();
      qa.note('note screen ${sw.elapsedMilliseconds} ms after Stop; '
          '${longNote.durationMs ~/ 60000} min saved');
      expect(longNote.durationMs, greaterThan(59 * 60000));
      final steps = <String>[];
      final seen = await qa.waitForStatus(longNote.id, ProcessingStatus.done,
          timeout: const Duration(minutes: 25), onTick: (n) async {
        final s = n.processingStatus.name;
        if (steps.isEmpty || !steps.last.endsWith(s)) {
          steps.add('${sw.elapsed.inSeconds}s $s');
        }
      });
      qa.note('done ${sw.elapsed.inMinutes} min ${sw.elapsed.inSeconds % 60} s after '
          'Stop; ${steps.join(', ')}');
      qa.note('statuses: ${seen.map((s) => s.name).join(' > ')}');
      await expectSummary(longNote.id);
      await qa.shot('long-note-summary');
    }, section: long, needs: ['M1'], timeout: const Duration(minutes: 28));

    await qa.check('M3', 'The 60 min transcript: many lines, 2+ speakers, scrolls; '
        'the player knows the full length', () async {
      final lines = await qa.services.repo.transcript(longNote.id);
      final speakers = {for (final l in lines) l.speaker};
      final lastMs = lines.isEmpty ? 0 : lines.last.startMs;
      qa.note('${lines.length} lines, speakers ${speakers.join(', ')}, last line at '
          '${lastMs ~/ 60000} min');
      expect(lines.length, greaterThan(100));
      expect(speakers.length, greaterThanOrEqualTo(2));
      expect(lastMs, greaterThan(55 * 60000));
      await qa.tap(find.text('Transcript'));
      await qa.waitFor(find.byType(TurnRow), what: 'transcript lines');
      final sw = Stopwatch()..start();
      for (var k = 0; k < 6; k++) {
        await t.fling(find.byType(Scrollable).first, const Offset(0, -3000), 4000);
        await qa.wait(const Duration(milliseconds: 600));
      }
      qa.note('6 fast scrolls in ${sw.elapsedMilliseconds} ms');
      await qa.shot('long-transcript-scrolled');
      final player = find.byType(LnMiniPlayer);
      if (player.evaluate().isNotEmpty) {
        final d = t.widget<LnMiniPlayer>(player.last).duration;
        qa.note('player length ${d.inMinutes} min');
        expect(d.inMinutes, greaterThanOrEqualTo(59));
      } else {
        qa.note('no mini player on screen (not checked)');
      }
    }, section: long, needs: ['M2'], timeout: const Duration(minutes: 3));

    await qa.check('M4', 'Ask on the 60 min note: an answer with a source', () async {
      if (!qa.onTop<NoteScreen>()) {
        await qa.home();
        await qa.tap(find.text(longNote.title));
        await qa.expectOnTop<NoteScreen>();
      }
      await qa.tap(find.text('Ask'));
      await qa.expectOnTop<AskChatScreen>();
      final input = find.byKey(const ValueKey('ask-input'));
      await qa.waitUntil(() async =>
              input.evaluate().isNotEmpty && t.widget<TextField>(input).enabled != false,
          what: 'the question box to be ready', timeout: const Duration(seconds: 20));
      await qa.type(input, 'What was decided about the deadline?');
      await qa.tap(find.byKey(const ValueKey('ask-send')));
      final sw = Stopwatch()..start();
      final chip = byLabelPrefix('Open the transcript at');
      await qa.waitFor(chip, what: 'an answer with a source chip',
          timeout: const Duration(seconds: 120));
      final msgs = await qa.services.chat.list(longNote.id);
      if (msgs.isNotEmpty) qa.note('answer in ${sw.elapsed.inSeconds} s: "${msgs.last.text}"');
      await qa.shot('long-answer');
      await qa.back();
    }, section: long, needs: ['M2'], timeout: const Duration(minutes: 4));

    await qa.check('M5', 'Notes list after all of this: every note done, none stuck',
        () async {
      await qa.home();
      final all = await qa.services.repo.all();
      final stuck = all.where((n) => n.processingStatus.inProgress).toList();
      qa.note('${all.length} notes: ${all.map((n) => n.processingStatus.name).toSet().join(', ')}');
      await qa.shot('notes-end');
      expect(stuck, isEmpty, reason: '${stuck.length} note(s) still processing');
    }, section: 'End', needs: ['K0'], timeout: const Duration(minutes: 2));
  });
}
