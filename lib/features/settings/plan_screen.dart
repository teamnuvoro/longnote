import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.plan].
class PlanScreen extends StatelessWidget {
  const PlanScreen({super.key});

  @override
  Widget build(BuildContext context) => PlaceholderScreen(
    title: 'Plan & billing',
    route: R.plan,
    tabRoot: false,
    purpose:
        'Current plan, trial end and next charge date + amount, how to cancel (Settings > your name > Subscriptions), restore purchases. Billing is still simulated (FakeBillingService).',
  );
}
