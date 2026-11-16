import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.ask].
class AskScreen extends StatelessWidget {
  const AskScreen({super.key});

  @override
  Widget build(BuildContext context) => PlaceholderScreen(
    title: 'Ask',
    route: R.ask,
    tabRoot: true,
    purpose:
        'Ask questions about a note: note picker (E3), starter questions, then the chat (E2). AskService in lib/core/notes/ask_service.dart.',
  );
}
