import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/config.dart';
import '../features/ask/ask_chat_screen.dart';
import '../features/ask/ask_screen.dart';
import '../features/ask/choose_note_sheet.dart';
import '../features/ask/last_note.dart';
import '../features/benchmark/benchmark_screen.dart';
import '../features/dev/widget_gallery_screen.dart';
import '../features/import/import_details_sheet.dart';
import '../features/import/import_progress_screen.dart';
import '../features/import/import_screen.dart';
import '../features/note/note_screen.dart';
import '../features/note/player_sheet.dart';
import '../features/note/share_sheet.dart';
import '../features/note/speakers_sheet.dart';
import '../features/note/summary_style_sheet.dart';
import '../features/notes/note_actions_sheet.dart';
import '../features/notes/notes_screen.dart';
import '../features/notes/search_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/paywall/paywall_screen.dart';
import '../features/paywall/trial_started_screen.dart';
import '../features/recording/discard_sheet.dart';
import '../features/recording/recording_screen.dart';
import '../features/settings/audio_language_screen.dart';
import '../features/settings/plan_screen.dart';
import '../features/settings/privacy_screen.dart';
import '../features/settings/settings_home_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/transcription_screen.dart';
import '../ui/theme.dart';
import 'routes.dart';
import 'shell.dart';
import 'sheet_page.dart';

/// Root navigator: detail screens, sheets and the recording modal cover the
/// tab bar (as in the Figma frames).
final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// Native iOS push (swipe-back works).
Page<void> _push(GoRouterState s, Widget child) =>
    CupertinoPage<void>(key: s.pageKey, name: s.name, child: child);

/// Full-screen modal (slides up), e.g. recording and the paywall.
Page<void> _modal(GoRouterState s, Widget child) => CupertinoPage<void>(
    key: s.pageKey, name: s.name, fullscreenDialog: true, child: child);

/// Modal bottom sheet.
Page<T> _sheet<T>(GoRouterState s, Widget child) =>
    SheetPage<T>(key: s.pageKey, name: s.name, child: child);

String _id(GoRouterState s) => s.pathParameters['id']!;

/// Where the app opens: onboarding -> paywall (once) -> Notes.
String initialLocation({required bool onboarded, required bool paywallSeen}) {
  if (!onboarded) return '/onboarding';
  if (!paywallSeen) return '/paywall?first=1';
  return '/notes';
}

GoRouter buildRouter({required String initialLocation}) => GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/onboarding',
          name: R.onboarding,
          pageBuilder: (c, s) => _push(s, const OnboardingScreen()),
        ),
        GoRoute(
          path: '/paywall',
          name: R.paywall,
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (c, s) {
            final first = s.uri.queryParameters['first'] == '1';
            // ?from=import: the paywall before an import (analytics placement).
            final fromImport = s.uri.queryParameters['from'] == 'import';
            return _modal(
              s,
              PaywallScreen(
                placement: first
                    ? 'first_run'
                    : fromImport
                        ? 'import'
                        : 'second_recording',
                onDone: first
                    ? (ctx, _) async {
                        await ctx
                            .read<AppServices>()
                            .kv
                            .setBool(AppServices.kvFirstPaywallSeen, true);
                        if (ctx.mounted) ctx.goNamed(R.notes);
                      }
                    : null,
              ),
            );
          },
          routes: [
            GoRoute(
              path: 'started',
              name: R.trialStarted,
              parentNavigatorKey: rootNavigatorKey,
              pageBuilder: (c, s) => _push(s, const TrialStartedScreen()),
            ),
          ],
        ),
        GoRoute(
          path: '/record',
          name: R.record,
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (c, s) => _modal(
              s,
              Theme(
                  data: lnRecordingTheme(),
                  child: RecordingScreen(
                      ready: s.uri.queryParameters[RecordingScreen.readyParam] == '1'))),
          routes: [
            GoRoute(
              path: 'discard',
              name: R.discard,
              parentNavigatorKey: rootNavigatorKey,
              pageBuilder: (c, s) => DialogPage<bool>(
                  key: s.pageKey, name: s.name, child: const DiscardSheet()),
            ),
          ],
        ),
        StatefulShellRoute.indexedStack(
          builder: (c, s, shell) => AppShell(shell: shell),
          branches: [
            // ---- Notes -------------------------------------------------------
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/notes',
                name: R.notes,
                builder: (c, s) => const NotesScreen(),
                routes: [
                  GoRoute(
                    path: 'search',
                    name: R.search,
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (c, s) => _push(s, const SearchScreen()),
                  ),
                  GoRoute(
                    path: ':id',
                    name: R.note,
                    parentNavigatorKey: rootNavigatorKey,
                    // D1/D2/D3/D8 = states of one screen.
                    pageBuilder: (c, s) {
                      rememberOpenedNote(c, _id(s)); // Ask preselects it
                      return _push(
                        s,
                        NoteScreen(
                          id: _id(s),
                          initialTab: s.uri.queryParameters['tab'] == 'transcript'
                              ? NoteTab.transcript
                              : null,
                          atMs: int.tryParse(s.uri.queryParameters['at'] ?? ''),
                        ));
                    },
                    routes: [
                      GoRoute(
                        path: 'actions',
                        name: R.noteActions,
                        parentNavigatorKey: rootNavigatorKey,
                        pageBuilder: (c, s) => _sheet(s, NoteActionsSheet(id: _id(s))),
                      ),
                      GoRoute(
                        path: 'speakers',
                        name: R.speakers,
                        parentNavigatorKey: rootNavigatorKey,
                        pageBuilder: (c, s) => _sheet(s, SpeakersSheet(id: _id(s))),
                      ),
                      GoRoute(
                        path: 'share',
                        name: R.share,
                        parentNavigatorKey: rootNavigatorKey,
                        pageBuilder: (c, s) => _sheet(s, ShareSheet(id: _id(s))),
                      ),
                      GoRoute(
                        path: 'style',
                        name: R.summaryStyle,
                        parentNavigatorKey: rootNavigatorKey,
                        pageBuilder: (c, s) =>
                            _sheet(s, SummaryStyleSheet(id: _id(s))),
                      ),
                      GoRoute(
                        path: 'player',
                        name: R.player,
                        parentNavigatorKey: rootNavigatorKey,
                        pageBuilder: (c, s) => _sheet(s, PlayerSheet(id: _id(s))),
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            // ---- Ask ---------------------------------------------------------
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/ask',
                name: R.ask,
                builder: (c, s) => const AskScreen(),
                routes: [
                  GoRoute(
                    path: 'choose',
                    name: R.askChoose,
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (c, s) => _sheet(s, const ChooseNoteSheet()),
                  ),
                  GoRoute(
                    path: ':id',
                    name: R.askChat,
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (c, s) => _push(s, AskChatScreen(id: _id(s))),
                  ),
                ],
              ),
            ]),
            // ---- Import ------------------------------------------------------
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/import',
                name: R.import,
                builder: (c, s) => const ImportScreen(),
                routes: [
                  GoRoute(
                    path: 'details',
                    name: R.importDetails,
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (c, s) => _sheet(s, const ImportDetailsSheet()),
                  ),
                  GoRoute(
                    path: 'progress/:id',
                    name: R.importProgress,
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (c, s) =>
                        _push(s, ImportProgressScreen(id: _id(s))),
                  ),
                ],
              ),
            ]),
            // ---- Settings ----------------------------------------------------
            // G2-G4 and the other settings pages are pushed above the shell
            // (no tab bar, as in the Figma frames).
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/settings',
                name: R.settings,
                builder: (c, s) => const SettingsHomeScreen(),
                routes: [
                  GoRoute(
                    path: 'audio-language',
                    name: R.audioLanguage,
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (c, s) => _push(s, const AudioLanguageScreen()),
                  ),
                  GoRoute(
                    path: 'summary-language',
                    name: R.summaryLanguage,
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (c, s) =>
                        _push(s, const AudioLanguageScreen(summary: true)),
                  ),
                  GoRoute(
                    path: 'summary-style',
                    name: R.defaultStyle,
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (c, s) => _sheet(s, const SummaryStyleSheet()),
                  ),
                  GoRoute(
                    path: 'transcription',
                    name: R.transcription,
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (c, s) => _push(s, const TranscriptionScreen()),
                  ),
                  GoRoute(
                    path: 'plan',
                    name: R.plan,
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (c, s) => _push(s, const PlanScreen()),
                  ),
                  GoRoute(
                    path: 'privacy',
                    name: R.privacy,
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (c, s) => _push(s, const PrivacyScreen()),
                  ),
                  GoRoute(
                    path: 'advanced',
                    name: R.advanced,
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (c, s) => _push(s, const SettingsScreen()),
                    // Developer screens exist only in dev builds.
                    routes: [
                      if (AppConfig.devTools)
                      GoRoute(
                        path: 'benchmark',
                        name: R.benchmark,
                        parentNavigatorKey: rootNavigatorKey,
                        pageBuilder: (c, s) => _push(s, const BenchmarkScreen()),
                        routes: [
                          GoRoute(
                            path: 'gallery',
                            name: R.gallery,
                            parentNavigatorKey: rootNavigatorKey,
                            pageBuilder: (c, s) =>
                                _push(s, const WidgetGalleryScreen()),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
          ],
        ),
      ],
    );
