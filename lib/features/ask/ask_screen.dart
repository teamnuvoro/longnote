import 'package:flutter/material.dart';

import '../../ui/widgets.dart';
import 'ask_view.dart';
import '../common/widgets.dart';

/// E1/E2 Ask tab (Figma 9:364, 9:465). The note picker (E3) is a sheet route.
class AskScreen extends StatelessWidget {
  const AskScreen({super.key});

  @override
  Widget build(BuildContext context) => const LnScaffold(
        backgroundColor: LnColors.paper,
        body: AskView(),
      );
}
