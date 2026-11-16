import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/util/coalescing_runner.dart';

void main() {
  test('a request during a run does not starve the event loop', () async {
    var runs = 0;
    Completer<void>? gate;
    final r = CoalescingRunner(() async {
      runs++;
      gate = Completer<void>();
      // Completes from the EVENT queue, like a database reply.
      Timer.run(gate!.complete);
      await gate!.future;
    });
    r.request();
    await Future<void>.delayed(Duration.zero); // run 1 is in flight
    r.request();
    r.request();
    // Would never finish with the old microtask re-scheduling.
    await Future<void>.delayed(const Duration(milliseconds: 50))
        .timeout(const Duration(seconds: 2));
    expect(runs, 2); // the in-flight run + exactly one follow-up
  });

  test('many requests before the run coalesce into one', () async {
    var runs = 0;
    final r = CoalescingRunner(() async => runs++);
    for (var i = 0; i < 10; i++) {
      r.request();
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(runs, 1);
  });

  test('close stops further runs', () async {
    var runs = 0;
    final r = CoalescingRunner(() async => runs++);
    r.close();
    r.request();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(runs, 0);
  });

  test('a failing run keeps the follow-up request', () async {
    var runs = 0;
    late CoalescingRunner r;
    r = CoalescingRunner(() async {
      runs++;
      if (runs == 1) {
        r.request(); // a change arrives during the run
        throw StateError('db busy');
      }
    });
    r.request();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(runs, 2);
  });
}
