import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.noteActions].
class NoteActionsSheet extends StatelessWidget {
  const NoteActionsSheet({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) => PlaceholderSheet(
    title: 'Note actions',
    route: R.noteActions,
    purpose:
        'Long-press menu on a note: Rename, Share or export…, Copy summary, and Delete note… (red, with confirmation). Header = note title + date · length · speakers.',
  );
}
