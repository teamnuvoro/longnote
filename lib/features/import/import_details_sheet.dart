import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.importDetails].
class ImportDetailsSheet extends StatelessWidget {
  const ImportDetailsSheet({super.key});

  @override
  Widget build(BuildContext context) => PlaceholderSheet(
    title: 'Before we start',
    route: R.importDetails,
    purpose:
        'File name + length + size, Name field, Language, Summary style, then "Import and transcribe". Creates a note with source = imported and import_file set; the cloud pipeline handles any length.',
  );
}
