import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'app/router.dart';
import 'app/routes.dart';
import 'app_services.dart';
import 'core/audio/pcm_source.dart';
import 'core/billing/trial_reminder.dart';
import 'core/diagnostics/crash_reporter.dart';
import 'ui/fonts.dart';
import 'ui/theme.dart';

Future<void> main() => launchApp();

/// The app's start. [sourceFactory] replaces the microphone: only the
/// simulator QA suite (integration_test/) passes one.
@visibleForTesting
Future<void> launchApp({PcmSource Function()? sourceFactory}) async {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  final reporter = await _startCrashReporter();
  await _launch(reporter, sourceFactory);
}

/// Opens the app; if start-up fails (database cannot open or migrate, disk
/// full) shows a plain "could not start" screen with Try again instead of a
/// launch screen that never goes away.
Future<void> _launch(CrashReporter reporter,
    [PcmSource Function()? sourceFactory]) async {
  final AppServices services;
  try {
    services = await AppServices.boot(sourceFactory: sourceFactory);
  } catch (e, st) {
    reporter.record('boot_failed', e, st);
    runApp(StartupFailedApp(
        onRetry: () => _launch(reporter, sourceFactory)));
    return;
  }
  final api = services.api;
  if (api != null) {
    reporter.send = (r) => api.call('report', r, timeout: const Duration(seconds: 20));
    // After launch settles; and again whenever the app comes back.
    Timer(const Duration(seconds: 8), () => unawaited(reporter.uploadPending()));
    AppLifecycleListener(onResume: () => unawaited(reporter.uploadPending()));
  }
  final onboarded = await services.kv.getBool(AppServices.kvOnboardingDone);
  // Phones that onboarded on v0.1 have already met the paywall rule; they go
  // straight to Notes.
  final paywallSeen = onboarded &&
      (await services.kv.getBool(AppServices.kvFirstPaywallSeen) ||
          await services.repo.count() > 0 ||
          // A subscriber reinstalling: no "Start free trial" for them.
          services.billing.entitlement.value.isActive);
  final router = buildRouter(
      initialLocation:
          initialLocation(onboarded: onboarded, paywallSeen: paywallSeen));
  router.routerDelegate.addListener(() {
    final uri = router.routerDelegate.currentConfiguration.uri;
    reporter.breadcrumb('route ${uri.path}');
  });
  // Tapping a "note ready" notification opens that note.
  void openNote(String id) =>
      router.pushNamed(R.note, pathParameters: {'id': id});
  LocalNotificationScheduler.onOpenNote = openNote;
  runApp(LongnoteApp(services: services, router: router));
  unawaited(services.reminderScheduler.launchNoteId().then((id) {
    if (id != null) openNote(id);
  }, onError: (_) {}));
}

/// Installed first, so errors during start-up are kept too.
Future<CrashReporter> _startCrashReporter() async {
  final support = await getApplicationSupportDirectory();
  final info = <String, Object?>{
    'os': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
  };
  try {
    final pi = await PackageInfo.fromPlatform();
    info['version'] = pi.version;
    info['build'] = pi.buildNumber;
  } catch (_) {}
  return CrashReporter(
      dir: Directory(p.join(support.path, 'diagnostics')), appInfo: info)
    ..install();
}

/// Shown only when [AppServices.boot] failed. No services, no router.
class StartupFailedApp extends StatefulWidget {
  const StartupFailedApp({super.key, required this.onRetry});
  final Future<void> Function() onRetry;

  @override
  State<StartupFailedApp> createState() => _StartupFailedAppState();
}

class _StartupFailedAppState extends State<StartupFailedApp> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: lnLightTheme(),
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Longnote could not start',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  const Text(
                      'Your recordings are still on this phone. This can happen '
                      'when the phone is almost full: free some space in iPhone '
                      'Settings › General › iPhone Storage, then try again.'),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            setState(() => _busy = true);
                            await widget.onRetry();
                            if (mounted) setState(() => _busy = false);
                          },
                    child: Text(_busy ? 'Starting…' : 'Try again'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

class LongnoteApp extends StatelessWidget {
  const LongnoteApp({super.key, required this.services, required this.router});

  final AppServices services;
  final GoRouter router;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: services),
        ChangeNotifierProvider.value(value: services.repo),
        ChangeNotifierProvider.value(value: services.recorder),
      ],
      child: MaterialApp.router(
        title: 'Longnote',
        debugShowCheckedModeBanner: false,
        // Light only outside recording (dark mode is out of scope for v1);
        // the recording route applies lnRecordingTheme() itself.
        theme: lnLightTheme(),
        themeMode: ThemeMode.light,
        routerConfig: router,
      ),
    );
  }
}
