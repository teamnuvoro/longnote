import 'package:flutter/material.dart';

import '../../ui/widgets.dart';
import '../common/widgets.dart';
import 'import_screen.dart';

/// F3 as its own screen (/import/progress/:id): the copy of one file, with
/// cancel, and recent imports. The Import tab shows the same card inline.
class ImportProgressScreen extends StatelessWidget {
  const ImportProgressScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: LnColors.paper,
        appBar: const LnNavBar(title: 'Import', backLabel: 'Back'),
        body: ImportBody(tabRoot: false, onlyJob: id),
      );
}
