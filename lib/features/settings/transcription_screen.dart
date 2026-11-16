import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.transcription].
class TranscriptionScreen extends StatelessWidget {
  const TranscriptionScreen({super.key});

  @override
  Widget build(BuildContext context) => PlaceholderScreen(
    title: 'Transcription & privacy',
    route: R.transcription,
    tabRoot: false,
    purpose:
        'Cloud (default: speakers, 60+ languages, audio deleted after transcription) vs On this phone (private, slower, no speakers). Where audio goes, step by step. iCloud backup switch. AppSettings.setTranscriptionMode.',
  );
}
