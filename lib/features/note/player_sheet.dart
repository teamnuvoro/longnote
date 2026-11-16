import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.player].
class PlayerSheet extends StatelessWidget {
  const PlayerSheet({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) => PlaceholderSheet(
    title: 'Player',
    route: R.player,
    purpose:
        'Full player: waveform with moment markers, 15 s back/forward, play/pause, speeds 0.8x-2x, list of marked moments (MomentStore).',
  );
}
