import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.importProgress].
class ImportProgressScreen extends StatelessWidget {
  const ImportProgressScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) => PlaceholderScreen(
    title: 'Copying',
    route: R.importProgress,
    tabRoot: false,
    purpose:
        'Progress while the file is copied into the app, then hands over to the processing pipeline.',
  );
}
