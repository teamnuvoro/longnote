import 'package:flutter/material.dart';

import '../../ui/widgets.dart';
import 'ask_view.dart';

/// E2 opened from a note (/ask/:id): the same Ask view with that note
/// preselected and a back button (covers the tab bar, like the note screen).
class AskChatScreen extends StatelessWidget {
  const AskChatScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: LnColors.paper,
        body: SafeArea(
          top: false,
          child: AskView(
              noteId: id, onBack: () => Navigator.of(context).maybePop()),
        ),
      );
}
