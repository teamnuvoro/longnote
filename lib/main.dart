import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'app/router.dart';
import 'app_services.dart';
import 'ui/fonts.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  final services = await AppServices.boot();
  final onboarded = await services.kv.getBool(AppServices.kvOnboardingDone);
  // Phones that onboarded on v0.1 have already met the paywall rule; they go
  // straight to Notes.
  final paywallSeen = onboarded &&
      (await services.kv.getBool(AppServices.kvFirstPaywallSeen) ||
          await services.repo.count() > 0);
  runApp(LongnoteApp(
    services: services,
    router: buildRouter(
        initialLocation:
            initialLocation(onboarded: onboarded, paywallSeen: paywallSeen)),
  ));
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
