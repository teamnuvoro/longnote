import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.askChat].
class AskChatScreen extends StatelessWidget {
  const AskChatScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) => PlaceholderScreen(
    title: 'Ask',
    route: R.askChat,
    tabRoot: false,
    purpose:
        'Chat about one note: questions, answers with source chips (speaker + time, tap to play from there), "not in this recording" when found = false. History in ChatStore.',
  );
}
