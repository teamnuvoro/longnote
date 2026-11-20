import 'package:go_router/go_router.dart';

import '../core/analytics/analytics.dart';

/// Logs `screen_viewed {screen: <route name>}` on every route change: tab
/// switches (`go`), pushes and sheets (`push`), and pops back to a screen.
/// The name is the top route's name (app/routes.dart `R.*`); a change that
/// leaves the same route on top (e.g. a redirect, a query change) is not
/// logged again.
class ScreenViewTracker {
  ScreenViewTracker(this.router, this.analytics) {
    router.routerDelegate.addListener(_onChange);
    _onChange(); // the first screen, if the router has parsed it already
  }

  final GoRouter router;
  final Analytics analytics;
  String? _last;

  /// The route name last logged (tests).
  String? get last => _last;

  /// The top route's name. go_router's `state` reads the leaf of the match
  /// list, and for an ImperativeRouteMatch (context.push) the pushed route's
  /// own matches, so pushes and sheets above the shell are seen too.
  String? _topName() {
    final config = router.routerDelegate.currentConfiguration;
    if (config.isEmpty) return null;
    try {
      return router.state.topRoute?.name;
    } catch (_) {
      return null; // an error page / empty match list: nothing to log
    }
  }

  void _onChange() {
    final name = _topName();
    if (name == null || name == _last) return;
    _last = name;
    analytics.log(AnalyticsEvent.screenViewed, props: {'screen': name});
  }

  void dispose() => router.routerDelegate.removeListener(_onChange);
}
