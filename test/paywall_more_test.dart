import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/features/paywall/paywall_more.dart';

void main() {
  Future<void> pump(WidgetTester t, {required bool firstRun}) =>
      t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: PaywallMore(firstRun: firstRun)))));

  testWidgets('first-run paywall offers the free first recording', (t) async {
    await pump(t, firstRun: true);
    expect(find.text('Can I try it without paying?'), findsOneWidget);
  });

  testWidgets('later paywall (free recording used) does not promise it',
      (t) async {
    await pump(t, firstRun: false);
    expect(find.text('Can I try it without paying?'), findsNothing);
    expect(find.text('How do I cancel?'), findsOneWidget);
  });

  testWidgets('opening a question shows its answer and reports its id',
      (t) async {
    final opened = <String>[];
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: PaywallMore(onFaqOpened: opened.add)))));
    await t.ensureVisible(find.text('How do I cancel?'));
    await t.tap(find.text('How do I cancel?'));
    await t.pumpAndSettle();
    expect(find.textContaining('you pay nothing'), findsOneWidget);
    expect(opened, ['cancel']);
  });
}
