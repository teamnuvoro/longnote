// Host side of `flutter drive` for the simulator QA suite (integration_test/).
// The app writes its own results and screenshots straight to QA_OUT on the
// host (so a force-quit run keeps them); this only saves the final report.
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
      timeout: const Duration(minutes: 45),
      writeResponseOnFailure: true,
      responseDataCallback: (data) async {
        final out = Platform.environment['QA_OUT'] ?? 'build/qa_out';
        final run = Platform.environment['QA_RUN'] ?? 'run';
        final f = File('$out/results/$run.driver.json');
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(data ?? {}));
      },
    );
