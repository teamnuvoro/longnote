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

  testWidgets('no trial on offer: no trial sentences', (t) async {
    await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(child: PaywallMore(trial: false)))));
    expect(find.textContaining('before your trial ends'), findsNothing);
    await t.ensureVisible(find.text('How do I cancel?'));
    await t.tap(find.text('How do I cancel?'));
    await t.pumpAndSettle();
    expect(find.textContaining('free trial'), findsNothing);
    expect(find.textContaining('end of the period you paid for'), findsOneWidget);
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
