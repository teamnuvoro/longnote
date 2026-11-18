import 'package:longnote/core/analytics/meta_sink.dart';
import 'package:longnote/core/analytics/remote_analytics.dart';
import 'package:longnote/core/analytics/tracking_consent.dart';

/// Records what would have gone to a remote analytics service.
class FakeSink implements AnalyticsSink {
  final events = <(String, Map<String, Object>)>[];
  final userIds = <String?>[];
  bool enabled = true;

  List<String> get names => [for (final e in events) e.$1];
  Map<String, Object> propsOf(String name) =>
      events.lastWhere((e) => e.$1 == name).$2;

  @override
  Future<void> track(String name, Map<String, Object> props) async {
    // Analytics must not call a sink while sharing is off.
    if (!enabled) throw StateError('track() while disabled: $name');
    events.add((name, props));
  }

  @override
  Future<void> setUserId(String? userId) async => userIds.add(userId);

  @override
  Future<void> setEnabled(bool enabled) async => this.enabled = enabled;
}

/// Fake Meta SDK: records calls in order.
class FakeMetaEvents implements MetaEvents {
  final calls = <String>[];
  bool? advertiserId;
  String? anonId = 'XZTEST-ANON-1';

  @override
  Future<void> initializeSdk() async => calls.add('init');
  @override
  Future<void> activateApp() async => calls.add('activate');
  @override
  Future<void> setAutoLogMetaDataEnabled(bool enabled) async =>
      calls.add('metadata:$enabled');
  @override
  Future<void> setAdvertiserIdCollectionEnabled(bool enabled) async {
    advertiserId = enabled;
    calls.add('advertiserId:$enabled');
  }

  @override
  Future<void> logCompletedRegistration() async =>
      calls.add('CompleteRegistration');
  @override
  Future<String?> anonymousId() async => anonId;
}

/// Fake ATT: [answer] is what the user taps; counts prompts.
class FakeTrackingConsent implements TrackingConsent {
  FakeTrackingConsent(
      {this.current = AttStatus.notDetermined, this.answer = AttStatus.denied});
  AttStatus current;
  AttStatus answer;
  int prompts = 0;

  @override
  Future<AttStatus> status() async => current;

  @override
  Future<AttStatus> request() async {
    if (current != AttStatus.notDetermined) return current;
    prompts++;
    current = answer;
    return answer;
  }
}
