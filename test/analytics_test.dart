import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/analytics/analytics.dart';

import 'helpers/test_env.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  test('logs every required event name with time, recording id and props',
      () async {
    for (final name in AnalyticsEvent.all) {
      await env.analytics.log(name, recordingId: 'r1', props: {'k': name});
      env.clock.advance(const Duration(seconds: 1));
    }
    final ev = await env.analytics.recent();
    expect(ev.map((e) => e.name).toSet(), AnalyticsEvent.all.toSet());
    expect(ev.first.name, AnalyticsEvent.all.last, reason: 'newest first');
    expect(ev.first.recordingId, 'r1');
    expect(ev.first.props['k'], AnalyticsEvent.all.last);
    expect(ev.first.ts, env.clock.now().subtract(const Duration(seconds: 1)));
  });

  test('the required names match the spec', () {
    expect(AnalyticsEvent.all, [
      'recording_started',
      'recording_completed',
      'recording_interrupted',
      'recording_recovered',
      'processing_failed',
      'processing_retried',
      'transcript_viewed',
      'summary_viewed',
      'export',
      'paywall_viewed',
      'trial_started',
      'subscription_purchased',
      'restore_tapped',
      'restore_result',
      'onboarding_completed',
      'onboarding_step',
      'paywall_faq_opened',
      'att_result',
      'screen_viewed',
      'paywall_plan_selected',
      'paywall_purchase_tapped',
      'paywall_purchase_result',
      'paywall_closed',
      'paywall_more_opened',
      'mic_permission',
      'notification_permission',
      'recording_paused',
      'recording_resumed',
      'recording_discarded',
      'search_used',
      'note_renamed',
      'note_deleted',
      'speaker_renamed',
      'summary_style_changed',
      'playback_started',
      'ask_sent',
      'ask_answered',
      'import_started',
      'import_completed',
      'import_failed',
      'setting_changed',
      'share_analytics_off',
      'rate_tapped',
      'support_tapped',
      'manage_subscription_tapped',
      'legal_link_opened',
      'delete_data_confirmed',
    ]);
  });

  test('counts and filter by name', () async {
    await env.analytics.log(AnalyticsEvent.export, props: {'kind': 'pdf'});
    await env.analytics.log(AnalyticsEvent.export, props: {'kind': 'audio'});
    await env.analytics.log(AnalyticsEvent.paywallViewed);
    expect(await env.analytics.counts(),
        {AnalyticsEvent.export: 2, AnalyticsEvent.paywallViewed: 1});
    final pdf = await env.analytics.recent(name: AnalyticsEvent.export);
    expect(pdf, hasLength(2));
    final pw = await env.analytics.recent(name: AnalyticsEvent.paywallViewed);
    expect(pw.single.props, isEmpty);
  });

  test('logging never throws, even if the DB is closed', () async {
    await env.db.close();
    await env.analytics.log(AnalyticsEvent.export); // must not throw
  });
}
