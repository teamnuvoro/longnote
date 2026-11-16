import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.trialStarted].
class TrialStartedScreen extends StatelessWidget {
  const TrialStartedScreen({super.key});

  @override
  Widget build(BuildContext context) => PlaceholderScreen(
    title: 'Your trial has started',
    route: R.trialStarted,
    tabRoot: false,
    purpose:
        'Trial started: exact charge date and amount, and why we ask for notification permission (the reminder 26 h before the charge). Continue goes to Notes.',
  );
}
