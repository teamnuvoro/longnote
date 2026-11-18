// The tracking profile the server needs for subscription events
// (lib/core/analytics/tracking_profile.dart). Fakes only: no network.
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/analytics/tracking_profile.dart';

import 'helpers/test_env.dart';

class _Device implements DeviceInfoSource {
  @override
  Future<List<String>?> extinfo() async => [
        'i2', 'com.novaralabs.longnote', '1.0.0', '112', '18.1', 'iPhone15,2',
        'en_IN', 'IST', '', '393', '852', '3.00', '6', '', '', 'Asia/Kolkata'
      ];
}

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  late List<Map<String, Object?>> sent;
  late bool share;
  late String? user;
  late bool att;
  late String? jws;
  bool fail = false;

  TrackingProfileSender make() {
    sent = [];
    share = true;
    user = 'u-1';
    att = false;
    jws = null;
    fail = false;
    return TrackingProfileSender(
      kv: env.kv,
      send: (b) async {
        if (fail) throw Exception('offline');
        user ??= 'u-new';
        sent.add(b);
      },
      shareEnabled: () async => share,
      knownUserId: () async => user,
      metaAnonId: () async => 'XZANON',
      attAuthorized: () async => att,
      transactionJws: () async => jws,
      device: _Device(),
    );
  }

  test('full profile while sharing; nothing re-sent when unchanged', () async {
    final s = make();
    expect(await s.sync(), isTrue);
    final b = sent.single;
    expect(b['share_analytics'], true);
    expect(b['meta_anon_id'], 'XZANON');
    expect(b['att_enabled'], false);
    expect([b['app_version'], b['os_version'], b['device_model'], b['locale']],
        ['1.0.0', '18.1', 'iPhone15,2', 'en_IN']);
    expect((b['extinfo'] as List).length, 16);
    expect(b.containsKey('transaction_jws'), isFalse);
    expect(await s.sync(), isFalse, reason: 'same profile: not sent again');
    // A relaunch over the same database: still nothing to send.
    expect(await make().sync(), isFalse);
  });

  test('a change is sent: ATT answer, a purchase (signed transaction)', () async {
    final s = make();
    await s.sync();
    att = true;
    expect(await s.sync(), isTrue);
    expect(sent.last['att_enabled'], true);
    jws = 'a.b.c';
    expect(await s.sync(), isTrue);
    expect(sent.last['transaction_jws'], 'a.b.c');
  });

  test('opt-out: only share_analytics=false leaves the phone', () async {
    final s = make();
    await s.sync();
    share = false;
    expect(await s.sync(), isTrue);
    expect(sent.last, {'share_analytics': false});
  });

  test('no server account yet: nothing (no sign-up just for analytics), '
      'unless right before a purchase', () async {
    final s = make();
    user = null;
    expect(await s.sync(), isFalse);
    expect(sent, isEmpty);
    expect(await s.sync(allowSignIn: true), isTrue);
    expect(sent, hasLength(1));
  });

  test('offline: never throws, retried on the next sync', () async {
    final s = make();
    fail = true;
    expect(await s.sync(), isFalse);
    fail = false;
    expect(await s.sync(), isTrue);
  });

  test('a change during a send is sent right after it', () async {
    final s = make();
    final first = s.sync();
    att = true;
    final second = s.sync();
    await Future.wait([first, second]);
    expect(sent.last['att_enabled'], true);
  });
}
