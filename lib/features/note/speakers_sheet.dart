import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.speakers].
class SpeakersSheet extends StatelessWidget {
  const SpeakersSheet({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) => PlaceholderSheet(
    title: 'Speakers',
    route: R.speakers,
    purpose:
        'Cancel | Speakers | Save. One row per voice with a name field and a sample line + play button (SpeakerStore.firstTurns). "Two of these are the same person? Merge speakers" (SpeakerStore.merge).',
  );
}
