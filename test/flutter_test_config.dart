import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/app/nav.dart';

/// Runs around every test file: each test starts with a fresh tap guard.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(NavGuard.reset);
  await testMain();
}
