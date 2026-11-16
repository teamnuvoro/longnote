import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.askChoose].
class ChooseNoteSheet extends StatelessWidget {
  const ChooseNoteSheet({super.key});

  @override
  Widget build(BuildContext context) => PlaceholderSheet(
    title: 'Choose a note',
    route: R.askChoose,
    purpose:
        'List of done notes with search; picking one opens the chat (R.askChat).',
  );
}
