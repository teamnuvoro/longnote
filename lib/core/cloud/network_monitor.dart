import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Is there a network interface at all? (Not a guarantee the server is
/// reachable; real request failures are handled by the pipeline.)
abstract class NetworkMonitor {
  Future<bool> isOnline();

  /// Emits true when a network comes back, false when it goes away.
  Stream<bool> get changes;
}

class ConnectivityPlusMonitor implements NetworkMonitor {
  ConnectivityPlusMonitor([Connectivity? c]) : _c = c ?? Connectivity();
  final Connectivity _c;

  static bool _online(List<ConnectivityResult> r) =>
      r.any((x) => x != ConnectivityResult.none);

  @override
  Future<bool> isOnline() async {
    try {
      return _online(await _c.checkConnectivity());
    } catch (_) {
      return true; // unknown: let the request decide
    }
  }

  @override
  Stream<bool> get changes =>
      _c.onConnectivityChanged.map(_online).distinct();
}

/// Tests / platforms without the plugin.
class ManualNetworkMonitor implements NetworkMonitor {
  ManualNetworkMonitor({bool online = true}) : _online = online;
  bool _online;
  final _ctl = StreamController<bool>.broadcast();

  set online(bool v) {
    if (v == _online) return;
    _online = v;
    _ctl.add(v);
  }

  bool get online => _online;

  @override
  Future<bool> isOnline() async => _online;

  @override
  Stream<bool> get changes => _ctl.stream;
}
