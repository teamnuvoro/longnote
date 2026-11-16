import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.import].
class ImportScreen extends StatelessWidget {
  const ImportScreen({super.key});

  @override
  Widget build(BuildContext context) => PlaceholderScreen(
    title: 'Import',
    route: R.import,
    tabRoot: true,
    purpose:
        'Bring in a recording: Files (iCloud Drive, Google Drive, Dropbox), Photos (the sound of a video), Voice Memos via the share sheet. We keep a copy on this phone.',
  );
}
