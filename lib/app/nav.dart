import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// One screen per tap: a second push within [window] of the last one is
/// dropped. A fast double tap on a row (or two rows) would otherwise push the
/// screen twice, since the page below still takes taps while the new one
/// slides in. Uses package:clock so widget tests' fake time applies.
abstract final class NavGuard {
  static const window = Duration(milliseconds: 400);
  static DateTime? _last;

  static bool allow() {
    final now = clock.now();
    final last = _last;
    if (last != null && now.difference(last).abs() < window) return false;
    _last = now;
    return true;
  }

  @visibleForTesting
  static void reset() => _last = null;
}

extension GuardedNav on BuildContext {
  /// [GoRouterHelper.pushNamed] for user taps, through [NavGuard]. Returns
  /// null (and pushes nothing) when the tap is a duplicate.
  Future<T?> pushOnce<T extends Object?>(
    String name, {
    Map<String, String> pathParameters = const <String, String>{},
    Map<String, dynamic> queryParameters = const <String, dynamic>{},
    Object? extra,
  }) {
    if (!NavGuard.allow()) return Future<T?>.value();
    return pushNamed<T>(name,
        pathParameters: pathParameters,
        queryParameters: queryParameters,
        extra: extra);
  }
}
