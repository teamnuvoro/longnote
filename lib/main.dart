import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_services.dart';
import 'features/home/home_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.boot();
  final onboarded = await services.kv.getBool(AppServices.kvOnboardingDone);
  runApp(LongnoteApp(services: services, onboarded: onboarded));
}

class LongnoteApp extends StatelessWidget {
  const LongnoteApp({super.key, required this.services, required this.onboarded});

  final AppServices services;
  final bool onboarded;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: services),
        ChangeNotifierProvider.value(value: services.repo),
        ChangeNotifierProvider.value(value: services.recorder),
      ],
      child: MaterialApp(
        title: 'Longnote',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: onboarded ? const HomeScreen() : const OnboardingScreen(),
      ),
    );
  }
}
