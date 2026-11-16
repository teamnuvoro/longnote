# Longnote app architecture (v1 build, 16 Nov 2026)

Brief for the screens session. What exists, where it lives, how to add a screen.
Server contract: `docs/BACKEND-API.md`. Design: `docs/DESIGN-FIGMA-V1.md` (fileKey `lGFjCA8QrgEbWcjVk6CP19`).

## 1. Folders

| Path | What |
|---|---|
| `lib/main.dart` | Boots `AppServices`, picks the first route, `MaterialApp.router` with `lnLightTheme()` |
| `lib/app_services.dart` | One container for every service (provider). Wires the pipeline, network wake-ups, foreground checks, notifications |
| `lib/app/` | `routes.dart` (route names + Figma frame per route), `router.dart` (go_router tree), `shell.dart` (4-tab shell), `sheet_page.dart` (sheet routes), `placeholder.dart` |
| `lib/ui/` | Design system: `tokens.dart`, `theme.dart`, `icons.dart`, `fonts.dart`, `widgets/`. Import everything with `import '../../ui/widgets.dart';` |
| `lib/features/<area>/` | Screens. New v1 screens: `notes/`, `note/`, `ask/`, `import/`, `settings/*_screen.dart`, `dev/`. v0.1 screens still used: `detail/`, `recording/`, `paywall/`, `onboarding/`, `settings/settings_screen.dart` (now "Advanced"), `benchmark/`. `home/` is unused (replaced by `notes/notes_screen.dart`) |
| `lib/core/cloud/` | Backend: config, anonymous auth, API client, TUS upload, encoder channel, network monitor, piece planner, cloud pipeline |
| `lib/core/notes/` | Speakers, moments, chat, search, Ask service, language list |
| `lib/core/settings/app_settings.dart` | User settings (kv-backed) |
| `lib/core/jobs/` | Persistent job queue, `NoteProcessor` (cloud vs on-device), on-device pipeline |
| `lib/core/{audio,recording,transcription,summary,billing,export,analytics,db,models,util}` | v0.1 parts (crash-safe recorder, whisper, summarizers, fake billing, PDF/share) |
| `ios/Runner/AppDelegate.swift` | Native channels: Apple summarizer, `longnote/audio_encoder` (AAC m4a), `longnote/files` (iCloud backup flag) |
| `assets/fonts/`, `assets/icons/`, `assets/FONTS.md` | Bundled OFL fonts + licences, Figma icons (SVG) |

## 2. Routes

Navigate by name: `context.pushNamed(R.note, pathParameters: {'id': id})`; sheets and modals are routes too
(`context.pushNamed(R.speakers, pathParameters: {'id': id})`). Transition: **push** = CupertinoPage (swipe back),
**sheet** = `SheetPage` (modal bottom sheet, scrim, grabber via `LnSheet`), **modal** = full-screen CupertinoPage sliding up.

| Name (`R.`) | Path | Figma | Type | Now |
|---|---|---|---|---|
| onboarding | /onboarding | (not drawn) | push | v0.1 OnboardingScreen, then goes to the paywall |
| paywall | /paywall (`?first=1` on first run) | A1 5:167 | modal | v0.1 PaywallScreen (restyle) |
| trialStarted | /paywall/started | A2 5:275 | push | placeholder |
| notes | /notes (tab) | B1 3:7, B2 3:141 | tab root | **minimal real** (attention list, Retry, day groups, Record pill) |
| search | /notes/search | B3 3:243 | push | placeholder |
| noteActions | /notes/:id/actions | B4 3:300 | sheet | placeholder |
| note | /notes/:id | D1 7:235, D2 7:332, D3 7:439, D8 8:923 | push | v0.1 DetailScreen; build `NoteScreen` (states of one screen) |
| speakers | /notes/:id/speakers | D4 7:546 | sheet | placeholder |
| share | /notes/:id/share | D5 8:288 | sheet | placeholder |
| summaryStyle | /notes/:id/style | D6 8:470 | sheet | placeholder |
| player | /notes/:id/player | D7 8:694 | sheet | placeholder |
| record | /record | C1 6:191, C2 6:322, C3 6:448 | modal (dark theme) | v0.1 RecordingScreen |
| discard | /record/discard | C4 6:579 | sheet | placeholder |
| ask | /ask (tab) | E1 9:364 | tab root | placeholder |
| askChoose | /ask/choose | E3 9:569 | sheet | placeholder |
| askChat | /ask/:id | E2 9:465 | push | placeholder |
| import | /import (tab) | F1 9:684 | tab root | placeholder |
| importDetails | /import/details | F2 9:781 | sheet | placeholder |
| importProgress | /import/progress/:id | F3 9:889 | push | placeholder |
| settings | /settings (tab) | G1 10:643 | tab root | **minimal real** (bound to AppSettings) |
| audioLanguage / summaryLanguage | /settings/audio-language, /settings/summary-language | G2 10:803 | push | placeholder (`AudioLanguageScreen(summary:)`) |
| defaultStyle | /settings/summary-style | D6 8:470 | sheet | placeholder (`SummaryStyleSheet()` without id) |
| transcription | /settings/transcription | G3 10:879 | push | placeholder |
| plan | /settings/plan | G4 10:961 | push | placeholder |
| privacy | /settings/privacy | - | push | v0.1 PrivacyScreen (text says on-device only: update with G3) |
| advanced → benchmark → gallery | /settings/advanced/benchmark/gallery | - | push | v0.1 settings; benchmark (tap version 7x on G1 or Advanced); widget gallery |

Detail screens, sheets and the recording modal use the **root** navigator (they cover the tab bar, as in Figma).
First launch: onboarding → paywall (once, kv `first_paywall_seen`) → Notes. Phones that already have notes skip the paywall.

## 3. Design system (`lib/ui/`)

Tokens: `LnColors` (palette 2:176 + derived fills, night colours), `LnSpeakerColors.of(i)`, `LnSpace` (page margin 20),
`LnRadius` (card 16, button 14, sheet 24, pill 999), `LnShadows`, `LnText` (every text style; variable fonts need
`fontVariations`, which these set: never build a raw `TextStyle(fontFamily: 'Geist')`).
Themes: `lnLightTheme()`, `lnRecordingTheme()` (dark, applied by the /record route).

| Widget | Figma | Use |
|---|---|---|
| `LnRecordPill` | RecordPill 2:166 | Floating, bottom-centre on Notes |
| `LnTabBar` | TabBar 2:165 | Used by `AppShell` |
| `LnPrimaryButton` / `LnSecondaryButton` / `LnDestructiveButton` | 2:170 / 2:172 / 2:174 | Full-width 54 px |
| `LnSmallButton`, `LnPillButton` (ink / outline / fill / onDark), `LnIconButton` (round / square) | B1, D2, G1 | Retry, Ask, Edit names, Manage, share/more/trash |
| `LnCardGroup` (+ `.settings`) , `LnHairline` | cards in B1/G1/B4 | White card, hairline dividers (inset 16, or 52 after icons) |
| `LnListRow` (+ `.toggle`, `large`, `destructive`) | G1 rows, B4 actions | Icon, label, value, chevron / toggle |
| `LnNoteRow`, `LnAttentionRow`, `LnProgressBar` | B1 | Note list row (preview or status+bar); needs-attention row |
| `LnChip`, `LnPillChip` (light / `dark`) | B1 trial chip, C1 chips, source chips | |
| `LnSegmentedControl<T>` | D2/D3 | Summary / Transcript |
| `LnSheet`, `LnGrabber`, `LnSheetAction`, `showLnSheet` | B4, D4 | Sheet body with title header or Cancel/Title/Save bar |
| `LnToggle` (normal 44x26, `small` 40x24) | G1, D3 | |
| `LnSearchField`, `LnTextField` | B1/B3, F2/D4 | |
| `LnStatusPill` (recording / paused / saved) | C1/C2 | Dark recording screen |
| `LnMiniPlayer` | D2/D3 | Pure view; wire to `PlaybackController` |
| `LnSectionLabel`, `LnOverline`, `LnLargeTitle`, `LnTopBar`, `LnTopBarIcon`, `LnSpeakerAvatar` | everywhere | |
| `LnIcon(LnIcons.x)` | Figma icons | Tinted SVG; add new icons to `assets/icons/` + the enum |

See them all: Settings → tap the version 7x → Benchmark → "Widget gallery" (`WidgetGalleryScreen`).

## 4. Data model (SQLite v2, `lib/core/db/app_database.dart`)

Migration v1→v2 keeps all notes (tested). A note is a row of `recordings`:

- v0.1: id, title, created_at, status (capture), duration_ms, segment_count, note, processing_status, processing_error, processing_progress.
- v2: `language` ('auto' or code), `summary_style` (`SummaryStyle.id`), `custom_instructions`, `output_language` ('same' or a name),
  `transcription_mode` ('cloud' | 'on_device'; NULL = setting), `transcript_source`, `source` ('recorded' | 'imported'),
  `import_file`, `progress` (0..1), `error_code`, `tries`, `updated_at`. NULL options = use `AppSettings`.
  New recordings get the current defaults (`AppServices.startRecording`).

| Table | What | API |
|---|---|---|
| `segments`, `gaps` | 5-min WAV parts; phone-call gaps (D3 "Paused 2 min for a phone call") | `RecordingRepository` |
| `transcript_lines` = **turns** | recording_id, speaker (KEY), start_ms, end_ms, text, language, seg_idx | `repo.transcript(id)` |
| `speakers` | (recording_id, speaker_key) → display_name, color_index | `SpeakerStore`: list, names, rename, merge, firstTurns |
| `summaries` | json (`MeetingSummary`, incl. `in_short`), engine, note, style | `repo.summary`, `MeetingSummary.parse` |
| `moments` | at_ms, label | `MomentStore` |
| `chat_messages` | role, text, sources (JSON [{speaker,start_ms}]), found | `ChatStore`, `AskService.ask` |
| `cloud_pieces` | upload/job state per piece (resumable) | internal to the pipeline |
| `notes_fts`, `turns_fts` | FTS5 search | `NoteSearch.search(q)` → per-note hits (title / summary / transcript with start_ms) |
| `kv` | settings, session, flags | `AppSettings`, `KvStore` |

Speaker keys: "1", "2" from the server; notes over 5 h use "<piece>:<n>" ("2:1" = "Speaker 1 (part 2)"). Show names via
`SpeakerStore.names(id)`; merge = rewrite turns + delete the speaker. On-device transcripts have `speaker = NULL`.

## 5. Processing pipeline

One persistent queue (`ProcessingJobQueue`), one note at a time, survives restarts, paused while recording.
`NoteProcessor` sends a note to the cloud pipeline (default) or the on-device whisper pipeline (setting, or the
note's override set by "Transcribe on this phone instead": `AppServices.transcribeOnPhoneInstead(id)`).

```
recordings.processing_status (ProcessingStatus):

none (local_only)
  └─ enqueue ─> queued ─> compressing ─> uploading (progress 0..1) ─> queuedOnServer ─> transcribing ─> summarizing ─> done
                 ▲            │              │                            │                 │ poll 5 s (1st min), 15 s, 10 min after 2 h
                 │            └──────────────┴──── offline / network error ────────────────┴──> waitingForNetwork ──(online)──┐
                 │                                                                                                         │
                 ├──── error (upstream_failed, server_error, encode_failed ...) ─> queued (retry 10 s, 20 s, 40 s ...)  <──┘
                 │                                      after 4 tries ─> failed(error, error_code, tries)  [Retry | Transcribe on this phone]
                 └──── limit_reached ─> failed(error_code = limit_reached), retried automatically after the reset (00:02 UTC / 15 min)
bad_request / too_long ─> failed at once (no retries)
```

- Steps per piece (`cloud_pieces`): native AAC encode (`<note>/cloud/piece_N.m4a`) → TUS upload (Location stored, `HEAD` to
  resume) → `transcribe-start` → poll `transcribe-status` → save turns + speakers → `ack` → summary (style, own instructions,
  output language; 100k-char parts merged) → done → local notification if the app is in the background.
- Over 5 h: 4-h pieces `<note>_p1..`, started together, stitched by start offset.
- Lost server state: `transcribe-status` → `not_found` (job cleaned up, or the anonymous user changed because its refresh
  token died) resets the piece and uploads + starts it again from the phone's m4a; pieces whose job belongs to an older
  user id are reset before polling. An existing on-device transcript is replaced only when the first cloud turns are saved.
- Waiting states do not use up tries (`JobDeferral`). App start and return to foreground poll at once (`pokeAll`);
  network back wakes waiters (`wakeNetworkWaiters`).
- Local audio is never modified or deleted by processing. The m4a is a derived copy (kept; can be cleaned later).
- UI reads: `processingStatus`, `processingProgress` (text), `progress` (bar), `processingError` (plain English from
  `plainEnglishError`), `errorCode`, `tries`. "Waiting & needs attention" = `processingStatus.needsAttention`.

Other entry points: `CloudPipeline.resummarize(id)` (D6 after changing style), `AskService.ask(id, q)` (E2),
`NoteSearch.search(q)` (B3), `AppServices.setExcludeFromBackup(v)` (G3).

## 6. Adding / filling a screen

1. Find the route in `lib/app/routes.dart` (the Figma frame is in `routeFrames`) and its placeholder in `lib/features/...`.
2. Read the frame: `get_design_context(fileKey, nodeId)` with the Figma MCP (load the figma-design-to-code skill first).
3. Replace the placeholder body with real UI built from `lib/ui/widgets.dart` + `LnText`/`LnColors` (no raw colours or fonts).
   Sheets: return an `LnSheet`. Detail screens: `Scaffold(backgroundColor: LnColors.paper, appBar: LnTopBar(...))`.
4. Data: `context.read<AppServices>()` for services; `context.watch<RecordingRepository>()` to rebuild on changes
   (every store calls `repo.changed()`).
5. New screen? Add a name to `R`, a frame to `routeFrames`, a `GoRoute` in `router.dart` (root navigator for detail
   screens/sheets), and a line in `test/ui_shell_test.dart`.
6. `flutter analyze` and `flutter test` must stay clean; iOS compile: `gh workflow run ios-build-check.yml -R teamnuvoro/longnote --ref <branch>`.

## 7. Screens A/E/F/G notes (screens session, 16 Nov)

- **Import:** Files and Photos use `file_picker` (Photos = `FileType.video`, PHPicker, no permission prompt). The file is
  copied into `<recordings>/<note>/import.<ext>` with MB progress (cancellable), its length read with just_audio, then a
  note `source = imported` is queued. Video is imported as is: the native compress step (`AudioEncoderPlugin`) reads its
  audio track. Imports always go to the cloud pipeline: the on-device pipeline reads WAV parts only, so in "On this
  phone" mode F2 says so and the button reads "Import and transcribe in the cloud" (per-note override).
- **TODO: files shared INTO the app** (share sheet / "Open in"). Needs a Share Extension target or
  `scene(_:openURLContexts:)` + `CFBundleDocumentTypes`, which means Xcode project edits not checkable here. Voice Memos
  row shows how to Save to Files and pick it instead.
- **Ask** preselects kv `last_opened_note` (written when a note route opens and when a note is picked in Ask).
  Source chips open `R.note` with `?tab=transcript&at=<ms>`.
- **Hinglish** is stored as `hi_en` and sent as `language: hi`, `language_hints: [hi, en]` (`languageRequest`).
- **Text line height:** FIXED in lib/ui/theme.dart (QA pass, 16 Nov): the theme's typography geometry has no
  heights/letter spacing (Material merged M3's 1.43 / 0.25 under every style at runtime), every textTheme slot comes
  from LnText, bodyMedium = `LnText.base` (Geist 15, normal leading). `LnScaffold`/`LnPlainSheet` no longer reset it.
- Links (privacy, terms, support email, App Store id): lib/features/common/links.dart, with TODOs for the owner.

## 8. QA pass (16 Nov)

- Whole-app flow tests: `test/flows/app_flow_test.dart` (harness `test/flows/flow_env.dart`: real router, screens,
  DB, queue and cloud pipeline; fake server/encoder/mic/network). Smoothness: `test/flows/smoothness_test.dart`.
- Navigate from user taps with `context.pushOnce(...)` (lib/app/nav.dart): a second push within 400 ms is dropped.
- The recorder writes only capture columns (`repo.updateCapture`), never the whole row.
- Notes list is built row by row (a day with hundreds of notes stays lazy); recording ticks rebuild only the bar.
- Settings pages are pushed above the shell (no tab bar). "Note ready" notification is asked once
  (`AppServices.noteQueuedByUser` -> NoteScreen / Import show `NoteReadyAskSheet`).
- Goldens compare on Linux only (skipped on macOS CI).
