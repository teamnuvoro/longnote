// Simulator QA run 3: after run 2's force-quit the app must say what it kept
// and process it. Then Settings (every screen), every tab and home button
// tapped quickly (nothing opens twice, no errors), and Import (Files ->
// details -> Import and transcribe -> summary).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/summary/summary_models.dart';
import 'package:longnote/features/common/external.dart';
import 'package:longnote/features/import/import_controller.dart';
import 'package:longnote/features/import/import_details_sheet.dart';
import 'package:longnote/features/import/import_screen.dart';
import 'package:longnote/features/note/note_screen.dart';
import 'package:longnote/features/note/summary_style_sheet.dart';
import 'package:longnote/features/notes/notes_screen.dart';
import 'package:longnote/features/notes/search_screen.dart';
import 'package:longnote/features/recording/discard_sheet.dart';
import 'package:longnote/features/recording/recording_screen.dart';
import 'package:longnote/features/settings/audio_language_screen.dart';
import 'package:longnote/features/settings/plan_screen.dart';
import 'package:longnote/features/settings/privacy_screen.dart';
import 'package:longnote/features/settings/settings_home_screen.dart';
import 'package:longnote/features/settings/transcription_screen.dart';
import 'package:longnote/features/ask/ask_screen.dart';
import 'package:longnote/ui/widgets.dart';

import 'support/file_pcm_source.dart';
import 'support/qa_harness.dart';

void main() {
  qaRunTest('QA run 3: recovery, settings, fast taps, import', (qa) async {
    final t = qa.tester;
    final opened = <Uri>[];
    External.openUrl = (u) async {
      opened.add(u);
      return true;
    };

    Future<void> openNoteShowsSummary(Recording n) async {
      if (!qa.onTop<NotesScreen>()) await qa.tap(byLabel('Notes'));
      await qa.tap(find.text(n.title));
      await qa.expectOnTop<NoteScreen>();
      final raw = await qa.services.repo.summary(n.id);
      expect(raw, isNotNull, reason: 'no summary saved');
      final short = (MeetingSummary.parse(raw!.json).inShort ?? '').trim();
      qa.note('in short: "$short"');
      expect(short, isNotEmpty);
      await qa.waitFor(
          find.textContaining(short.length > 30 ? short.substring(0, 30) : short),
          what: 'the summary on screen');
      await qa.shot('summary');
      await qa.back();
      await qa.expectOnTop<NotesScreen>();
    }

    // ------------------------------------------------------------ Recovery
    const rc = 'Force-quit';
    Recording? killed;
    await qa.check('F1', 'After the force-quit: "The app closed while recording" '
        'with the time kept', () async {
      await qa.launch();
      await passFirstRunIfShown(qa);
      await qa.expectOnTop<NotesScreen>();
      final all = await qa.services.repo.all();
      final hit = all.where((n) => (n.note ?? '').startsWith('Interrupted'));
      expect(hit, isNotEmpty, reason: 'no note was marked interrupted');
      killed = hit.first;
      qa.note('note "${killed!.title}": ${killed!.note}, ${killed!.durationMs} ms');
      await qa.waitFor(find.text('The app closed while recording'));
      final kept = find.textContaining('We kept what was saved:');
      await qa.waitFor(kept);
      qa.note('banner: "${(t.widget<Text>(kept.first)).data}"');
      expect(killed!.durationMs, greaterThan(7000));
    }, section: rc);

    await qa.check('F2', 'The interrupted note processes to a summary', () async {
      final seen = await qa.waitForStatus(killed!.id, ProcessingStatus.done,
          timeout: const Duration(minutes: 5));
      qa.note('statuses: ${seen.map((s) => s.name).join(' > ')}');
      await openNoteShowsSummary((await qa.services.repo.get(killed!.id))!);
    }, section: rc, needs: ['F1'], timeout: const Duration(minutes: 6));

    // ------------------------------------------------------------ Settings
    const st = 'Settings';
    final settings = qa.services.settings;
    final origLang = await settings.audioLanguage();
    final origStyle = await settings.defaultStyle();

    Future<void> toSettings() async {
      if (!qa.onTop<SettingsHomeScreen>()) await qa.tap(byLabel('Settings'));
      await qa.expectOnTop<SettingsHomeScreen>();
    }

    await qa.check('G1', 'Audio language: choose Hindi, the row shows it', () async {
      await toSettings();
      await qa.tap(find.text('Audio language'));
      await qa.expectOnTop<AudioLanguageScreen>();
      await qa.type(find.byType(TextField), 'Hindi');
      await qa.tap(find.text('Hindi').last);
      await qa.expectOnTop<SettingsHomeScreen>();
      await qa.waitFor(find.text('Hindi'));
      expect(await settings.audioLanguage(), 'hi');
      await settings.setAudioLanguage(origLang);
    }, section: st);

    await qa.check('G2', 'Summary language screen opens and comes back', () async {
      await toSettings();
      await qa.tap(find.text('Summary language'));
      await qa.expectOnTop<AudioLanguageScreen>();
      await qa.shot('summary-language');
      await qa.back();
      await qa.expectOnTop<SettingsHomeScreen>();
    }, section: st);

    await qa.check('G3', 'Summary style: choose "Lecture", Save, the row shows it',
        () async {
      await toSettings();
      await qa.tap(find.text('Summary style'));
      await qa.expectOnTop<SummaryStyleSheet>();
      await qa.tap(byLabel('Lecture → study notes'));
      await qa.tap(find.text('Save'));
      await qa.expectOnTop<SettingsHomeScreen>();
      await qa.waitFor(find.textContaining('Lecture'));
      expect((await settings.defaultStyle()).id, 'lecture');
      await settings.setDefaultStyle(origStyle);
    }, section: st);

    await qa.check('G4', 'Transcription screen (Cloud) opens and comes back', () async {
      await toSettings();
      await qa.tap(find.text('Transcription'));
      await qa.expectOnTop<TranscriptionScreen>();
      await qa.shot('transcription');
      await qa.back();
      await qa.expectOnTop<SettingsHomeScreen>();
    }, section: st);

    await qa.check('G5', '"What happens to your audio" opens and comes back', () async {
      await toSettings();
      await qa.tap(find.text('What happens to your audio'));
      await qa.expectOnTop<PrivacyScreen>();
      await qa.shot('privacy');
      await qa.back();
      await qa.expectOnTop<SettingsHomeScreen>();
    }, section: st);

    await qa.check('G6', 'Plan & billing: trial, reminder and charge dates', () async {
      await toSettings();
      await qa.tap(find.text('Manage'));
      await qa.expectOnTop<PlanScreen>();
      await qa.waitFor(find.text('First charge'));
      await qa.shot('plan');
      await qa.back();
      await qa.expectOnTop<SettingsHomeScreen>();
    }, section: st);

    await qa.check('G7', 'Speaker labels toggle, Privacy policy, Terms, Contact us',
        () async {
      await toSettings();
      final before = await settings.speakerLabels();
      final toggle = find.descendant(
          of: find.widgetWithText(LnListRow, 'Speaker labels'),
          matching: find.byType(LnToggle));
      await qa.tap(toggle);
      expect(await settings.speakerLabels(), !before);
      await qa.tap(toggle);
      expect(await settings.speakerLabels(), before);
      for (final row in ['Privacy policy', 'Terms of use', 'Contact us']) {
        final n = opened.length;
        await qa.scrollTo(find.text(row), within: find.byType(SettingsHomeScreen));
        await qa.tap(find.text(row));
        expect(opened.length, n + 1, reason: '$row opened nothing');
        qa.note('$row -> ${opened.last.scheme}:${opened.last.host}${opened.last.path}');
      }
      expect(qa.onTop<SettingsHomeScreen>(), isTrue);
    }, section: st);

    // ------------------------------------------------------------ Fast taps
    const ft = 'Fast taps';
    await qa.check('H1', 'Every tab tapped fast, 3 rounds: no error, ends on Notes',
        () async {
      await qa.home();
      for (var round = 0; round < 3; round++) {
        for (final tab in ['Ask', 'Import', 'Settings', 'Notes']) {
          await qa.tap(byLabel(tab), after: const Duration(milliseconds: 90));
        }
      }
      await qa.wait(const Duration(seconds: 1));
      await qa.expectOnTop<NotesScreen>();
      expect(t.widget<LnTabBar>(find.byType(LnTabBar)).currentIndex, 0);
      await qa.tap(byLabel('Ask'));
      await qa.expectOnTop<AskScreen>();
      await qa.tap(byLabel('Import'));
      await qa.expectOnTop<ImportScreen>();
      await qa.tap(byLabel('Notes'));
      await qa.expectOnTop<NotesScreen>();
    }, section: ft);

    // Two taps 60 ms apart on the same spot (the second lands on whatever is
    // there by then, like a fast finger).
    Future<void> doubleTap(Finder f) async {
      await qa.waitFor(f);
      final at = t.getCenter(f.hitTestable().first);
      await t.tapAt(at);
      await t.pump(const Duration(milliseconds: 60));
      await t.tapAt(at);
      await qa.wait(const Duration(milliseconds: 1200));
    }

    await qa.check('H2', 'Double-tap search, trial chip and a note: each opens once',
        () async {
      await qa.home();
      await doubleTap(find.byType(LnSearchField));
      expect(qa.count<SearchScreen>(), 1, reason: 'search opened twice');
      await qa.tap(byLabel('Cancel'));
      await qa.expectOnTop<NotesScreen>();

      await doubleTap(find.textContaining('Trial ·'));
      expect(qa.count<PlanScreen>(), 1, reason: 'plan opened twice');
      await qa.back();
      await qa.expectOnTop<NotesScreen>();

      final notes = await qa.services.repo.all();
      final done = notes.firstWhere((n) => n.processingStatus == ProcessingStatus.done);
      await doubleTap(find.text(done.title));
      expect(qa.count<NoteScreen>(), 1, reason: 'note opened twice');
      await qa.back();
      await qa.expectOnTop<NotesScreen>();
    }, section: ft);

    await qa.check('H3', 'Double-tap Record: one recording screen; Discard keeps no note',
        () async {
      await qa.home();
      final before = (await qa.services.repo.all()).length;
      FilePcmSource.nextPath = null; // silence
      await doubleTap(find.text('Record'));
      expect(qa.count<RecordingScreen>(), 1, reason: 'recording opened twice');
      expect(qa.services.recorder.isActive, isTrue);
      await qa.wait(const Duration(seconds: 2));
      await qa.tap(byLabel('Discard'));
      await qa.expectOnTop<DiscardSheet>();
      await qa.tap(find.text('Discard recording'));
      await qa.expectOnTop<NotesScreen>();
      await qa.waitUntil(() async => !qa.services.recorder.isActive,
          what: 'the recorder to stop');
      expect((await qa.services.repo.all()).length, before);
    }, section: ft);

    // ------------------------------------------------------------ Import
    const im = 'Import';
    final picker = HostFilePicker(Qa.audio('import_clip.m4a'));
    ImportController.picker = picker;
    Recording? imported;
    await qa.check('I1', 'Import -> Files (host file) -> details -> Import and '
        'transcribe -> listed', () async {
      await qa.home();
      await qa.tap(byLabel('Import'));
      await qa.expectOnTop<ImportScreen>();
      await qa.tap(find.text('Files'));
      await qa.expectOnTop<ImportDetailsSheet>(timeout: const Duration(seconds: 15));
      await qa.waitFor(find.text('import clip'), what: 'the suggested name');
      await qa.shot('details');
      await qa.tap(find.text('Import and transcribe'));
      await qa.waitFor(find.text('Recent imports'), timeout: const Duration(seconds: 30));
      final all = await qa.services.repo.all();
      imported = all.firstWhere((n) => n.source == 'imported');
      qa.note('imported "${imported!.title}", ${imported!.durationMs} ms '
          '(length read by the real iOS player)');
      expect(imported!.durationMs, inInclusiveRange(5000, 7000));
    }, section: im);

    await qa.check('I2', 'The imported note processes to a summary', () async {
      final seen = await qa.waitForStatus(imported!.id, ProcessingStatus.done,
          timeout: const Duration(minutes: 5));
      qa.note('statuses: ${seen.map((s) => s.name).join(' > ')}');
      await qa.tap(byLabel('Notes'));
      await openNoteShowsSummary((await qa.services.repo.get(imported!.id))!);
    }, section: im, needs: ['I1'], timeout: const Duration(minutes: 6));
  });
}
