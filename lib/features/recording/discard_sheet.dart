import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.discard].
class DiscardSheet extends StatelessWidget {
  const DiscardSheet({super.key});

  @override
  Widget build(BuildContext context) => PlaceholderSheet(
    title: 'Discard this recording?',
    route: R.discard,
    purpose:
        'Confirm before deleting the recording being made. Keep recording (primary) / Discard (destructive). Only path that deletes audio besides deleting a note.',
  );
}
