import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.share].
class ShareSheet extends StatelessWidget {
  const ShareSheet({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) => PlaceholderSheet(
    title: 'Share & export',
    route: R.share,
    purpose:
        'PDF, summary text, transcript text (with speaker names), original audio. Uses ShareService / PdfExporter.',
  );
}
