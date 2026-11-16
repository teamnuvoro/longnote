import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.search].
class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context) => PlaceholderScreen(
    title: 'Search',
    route: R.search,
    tabRoot: false,
    purpose:
        'Search titles, summaries and transcripts as you type (NoteSearch in lib/core/notes/search.dart). Group hits per note; tap a transcript hit to open the note at that moment (R.note with ?tab=transcript&at=<ms>).',
  );
}
