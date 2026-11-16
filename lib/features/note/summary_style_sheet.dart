import 'package:flutter/widgets.dart';

import '../../app/placeholder.dart';
import '../../app/routes.dart';

/// PLACEHOLDER for the screens session. Figma: see routeFrames[R.summaryStyle].
class SummaryStyleSheet extends StatelessWidget {
  const SummaryStyleSheet({super.key, this.id});

  /// Null = the default style in Settings.
  final String? id;

  @override
  Widget build(BuildContext context) => PlaceholderSheet(
    title: 'Summary style',
    route: R.summaryStyle,
    purpose:
        'Pick one of the 9 SummaryStyle templates or write your own instructions (max 1000 chars), then re-summarize (CloudPipeline.resummarize). Without a note id it sets the default style (Settings).',
  );
}
