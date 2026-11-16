import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'app/router.dart';
import 'app_services.dart';
import 'core/diagnostics/crash_reporter.dart';
import 'ui/fonts.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  final reporter = await _startCrashReporter();
  final services = await AppServices.boot();
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
          await services.repo.count() > 0);
  final router = buildRouter(
      initialLocation:
          initialLocation(onboarded: onboarded, paywallSeen: paywallSeen));
  router.routerDelegate.addListener(() {
    final uri = router.routerDelegate.currentConfiguration.uri;
    reporter.breadcrumb('route ${uri.path}');
  });
  runApp(LongnoteApp(services: services, router: router));
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
