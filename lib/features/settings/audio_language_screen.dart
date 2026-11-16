import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.audioLanguage].
class AudioLanguageScreen extends StatelessWidget {
  const AudioLanguageScreen({super.key, this.summary = false});

  /// true = "Summary language" variant.
  final bool summary;

  @override
  Widget build(BuildContext context) => PlaceholderScreen(
    title: summary ? 'Summary language' : 'Audio language',
    route: R.audioLanguage,
    tabRoot: false,
    purpose:
        '"Detect automatically" + 60 languages (lib/core/notes/languages.dart) with search. Saves AppSettings.setAudioLanguage. Summary variant: "Same as audio" + names, saves setSummaryLanguage.',
  );
}
