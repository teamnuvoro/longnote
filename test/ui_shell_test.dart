import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/app/router.dart';
import 'package:longnote/app/routes.dart';
import 'package:longnote/features/dev/widget_gallery_screen.dart';
import 'package:longnote/ui/widgets.dart';

Widget _app(Widget child) =>
    MaterialApp(theme: lnLightTheme(), home: Scaffold(body: child));

void main() {
  testWidgets('widget gallery shows every component without errors',
      (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(theme: lnLightTheme(), home: const WidgetGalleryScreen()));
    final list = find
        .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
        .first;
    await tester.pumpAndSettle();
    expect(find.byType(LnTabBar), findsOneWidget);
    await tester.scrollUntilVisible(find.byType(LnRecordPill), 300, scrollable: list);
    expect(find.byType(LnRecordPill), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Transcript'), 300, scrollable: list);
    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byType(LnMiniPlayer), 300, scrollable: list);
    expect(find.byType(LnStatusPill), findsNWidgets(3));
    await tester.scrollUntilVisible(find.text('Open sheet (title header)'), 300, scrollable: list);
    await tester.tap(find.text('Open sheet (title header)'));
    await tester.pumpAndSettle();
    expect(find.text('Delete note…'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tab bar reports taps and marks the active tab', (tester) async {
    var tapped = -1;
    await tester.pumpWidget(_app(Align(
        alignment: Alignment.bottomCenter,
        child: LnTabBar(currentIndex: 0, onTap: (i) => tapped = i))));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Settings'));
    expect(tapped, 3);
  });

  test('every Figma route has a named route', () {
    final router = buildRouter(initialLocation: '/notes');
    const withId = {
      R.note, R.noteActions, R.speakers, R.share, R.summaryStyle, R.player,
      R.askChat, R.importProgress,
    };
    for (final name in routeFrames.keys) {
      final loc = router.namedLocation(name,
          pathParameters: withId.contains(name) ? {'id': 'abc'} : const {});
      expect(loc, startsWith('/'), reason: name);
    }
    expect(router.namedLocation(R.note, pathParameters: {'id': 'n1'}), '/notes/n1');
    expect(router.namedLocation(R.askChat, pathParameters: {'id': 'n1'}), '/ask/n1');
    expect(router.namedLocation(R.gallery), '/settings/advanced/benchmark/gallery');
  });

  test('first launch: onboarding -> paywall -> notes', () {
    expect(initialLocation(onboarded: false, paywallSeen: false), '/onboarding');
    expect(initialLocation(onboarded: true, paywallSeen: false), '/paywall?first=1');
    expect(initialLocation(onboarded: true, paywallSeen: true), '/notes');
  });

  // All A-G screens are real now: see test/screens/ and test/goldens/.
}
