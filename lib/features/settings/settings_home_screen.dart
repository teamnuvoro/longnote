import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../app/nav.dart';
import '../../app_services.dart';
import '../../core/billing/billing_service.dart';
import '../../core/models/recording.dart';
import '../../core/notes/languages.dart';
import '../../core/summary/summary_style.dart';
import '../../ui/widgets.dart';
import '../common/dates.dart';
import '../common/external.dart';
import '../common/links.dart';
import '../paywall/trial_copy.dart';
import '../common/widgets.dart';

/// G1 Settings (Figma 10:643). Plan card -> G4; note defaults; transcription
/// and privacy; help (mail, review, share); legal links; restore; version.
/// Tapping the version 7 times opens the hidden benchmark (and gallery).
class SettingsHomeScreen extends StatefulWidget {
  const SettingsHomeScreen({super.key});
  @override
  State<SettingsHomeScreen> createState() => _SettingsHomeScreenState();
}

class _SettingsHomeScreenState extends State<SettingsHomeScreen> {
  int _taps = 0;
  _Values? _v;
  String _version = '';

  AppServices get _s => context.read<AppServices>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reload();
      _loadVersion();
    });
  }

  Future<void> _reload() async {
    if (!mounted) return;
    final s = _s.settings;
    final v = _Values(
      audio: audioLanguageFor(await s.audioLanguage()).name,
      summary: await s.summaryLanguage(),
      style: await s.defaultStyle(),
      speakers: await s.speakerLabels(),
      mode: await s.transcriptionMode(),
    );
    if (mounted) setState(() => _v = v);
  }

  Future<void> _loadVersion() async {
    try {
      final i = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = '${i.version} (${i.buildNumber})');
    } catch (_) {}
  }

  Future<void> _open(String route) async {
    await context.pushOnce(route);
    await _reload();
  }

  String get _versionLine =>
      _version.isEmpty ? 'Longnote' : 'Longnote $_version';

  Future<void> _mail(String subject) => openOrExplain(
        context,
        AppLinks.mail(subject: subject, body: '\n\n—\n$_versionLine'),
        fallbackCopy: AppLinks.supportEmail,
        failText:
            'No mail app is set up. We copied ${AppLinks.supportEmail} for you.',
      );

  Future<void> _rate() async {
    final ok = await External.requestReview();
    if (ok || !mounted) return;
    await openOrExplain(context, AppLinks.appStoreUrl);
  }

  Future<void> _restore() async {
    final s = _s;
    await s.billing.restore();
    if (!mounted) return;
    final e = s.billing.entitlement.value;
    showNote(
        context,
        e.isActive
            ? 'Your ${planName(planForId(e.planId)).toLowerCase()} plan is active.'
            : 'No purchase found to restore on this Apple ID.');
  }

  void _versionTap() {
    if (++_taps >= 7) {
      _taps = 0;
      context.pushOnce(R.benchmark);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    final s = _s;
    return LnScaffold(
      backgroundColor: LnColors.paper,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
          children: [
            const LnLargeTitle('Settings'),
            ValueListenableBuilder<Entitlement>(
              valueListenable: s.billing.entitlement,
              builder: (_, e, _) =>
                  _PlanCard(e: e, onManage: () => _open(R.plan)),
            ),
            const SizedBox(height: 18),
            const LnSectionLabel('Notes'),
            LnCardGroup.settings(children: [
              LnListRow(
                  icon: LnIcons.globe,
                  label: 'Audio language',
                  value: v?.audio,
                  onTap: () => _open(R.audioLanguage)),
              LnListRow(
                  icon: LnIcons.text,
                  label: 'Summary language',
                  value: v == null
                      ? null
                      : (v.summary == 'same' ? 'Same as audio' : v.summary),
                  onTap: () => _open(R.summaryLanguage)),
              LnListRow(
                  icon: LnIcons.template,
                  label: 'Summary style',
                  value: v?.style.label,
                  onTap: () => _open(R.defaultStyle)),
              LnListRow.toggle(
                icon: LnIcons.users,
                label: 'Speaker labels',
                value: v?.speakers ?? true,
                onChanged: v == null
                    ? null
                    : (x) async {
                        setState(() => _v = v.copyWith(speakers: x));
                        await s.settings.setSpeakerLabels(x);
                      },
              ),
            ]),
            const SizedBox(height: 18),
            const LnSectionLabel('Privacy'),
            LnCardGroup.settings(children: [
              LnListRow(
                  icon: LnIcons.cloud,
                  label: 'Transcription',
                  value: v == null
                      ? null
                      : (v.mode == TranscriptionMode.cloud
                          ? 'Cloud'
                          : 'On this phone'),
                  onTap: () => _open(R.transcription)),
              LnListRow(
                  icon: LnIcons.shield,
                  label: 'What happens to your audio',
                  onTap: () => _open(R.privacy)),
            ]),
            const SizedBox(height: 18),
            const LnSectionLabel('Help'),
            LnCardGroup.settings(children: [
              LnListRow(
                  icon: LnIcons.mail,
                  label: 'Contact us',
                  onTap: () => _mail('Longnote help')),
              LnListRow(
                  icon: LnIcons.bulb,
                  label: 'Suggest a feature',
                  onTap: () => _mail('Longnote feature idea')),
              LnListRow(icon: LnIcons.star, label: 'Rate Longnote', onTap: _rate),
              LnListRow(
                  icon: LnIcons.share,
                  label: 'Share with a friend',
                  onTap: () => External.shareText(
                      'I use Longnote to record long meetings and lectures and get notes with who said what: ${AppLinks.appStoreUrl}',
                      subject: 'Longnote')),
            ]),
            const SizedBox(height: 18),
            const LnSectionLabel('About'),
            LnCardGroup.settings(children: [
              LnListRow(
                  icon: LnIcons.lock,
                  label: 'Privacy policy',
                  onTap: () => openOrExplain(context, AppLinks.privacyPolicy)),
              LnListRow(
                  icon: LnIcons.text,
                  label: 'Terms of use',
                  onTap: () => openOrExplain(context, AppLinks.terms)),
              LnListRow(
                  icon: LnIcons.refresh,
                  label: 'Restore purchases',
                  showChevron: false,
                  onTap: _restore),
              LnListRow(
                  icon: LnIcons.more,
                  label: 'Advanced',
                  onTap: () => _open(R.advanced)),
            ]),
            const SizedBox(height: 18),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _versionTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                    child: Text(
                        _version.isEmpty ? 'Longnote' : 'Version $_version',
                        key: const ValueKey('settings-version'),
                        style: LnText.meta.copyWith(color: LnColors.ink3))),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _Values {
  _Values(
      {required this.audio,
      required this.summary,
      required this.style,
      required this.speakers,
      required this.mode});
  final String audio;
  final String summary;
  final SummaryStyle style;
  final bool speakers;
  final TranscriptionMode mode;

  _Values copyWith({bool? speakers}) => _Values(
      audio: audio,
      summary: summary,
      style: style,
      speakers: speakers ?? this.speakers,
      mode: mode);
}

/// Dark plan card at the top of G1.
class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.e, required this.onManage});
  final Entitlement e;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final plan = planForId(e.planId);
    final String title;
    final String sub;
    if (e.status == EntitlementStatus.trial && e.trialEndsAt != null) {
      title = 'Longnote · ${planName(plan)}';
      sub = e.willRenew
          ? 'Free trial until ${weekdayMonthDay(e.trialEndsAt!)}, then '
              '${plan.priceLabel} ${perPeriodWords(plan)}.'
          : 'Cancelled · free until ${weekdayMonthDay(e.trialEndsAt!)}.';
    } else if (e.isActive) {
      title = 'Longnote · ${planName(plan)}';
      sub = e.renewsAt == null
          ? '${plan.priceLabel} ${perPeriodWords(plan)}.'
          : !e.willRenew
              ? 'Cancelled · ends ${monthDayYear(e.renewsAt!)}.'
          : 'Renews ${monthDayYear(e.renewsAt!)} · ${plan.priceLabel} ${perPeriodWords(plan)}.';
    } else {
      title = 'Longnote · Free';
      sub = 'Your first recording is free, any length.';
    }
    return LnPressable(
      onPressed: onManage,
      pressedOpacity: 0.85,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
            color: LnColors.ink,
            borderRadius: BorderRadius.circular(LnRadius.card)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: LnText.rowTitle.copyWith(color: LnColors.card)),
              const SizedBox(height: 3),
              Text(sub, style: LnText.meta.copyWith(color: LnColors.nightText2)),
            ]),
          ),
          const SizedBox(width: 14),
          LnPillButton(
              label: 'Manage', style: LnPillStyle.onDark, onPressed: onManage),
        ]),
      ),
    );
  }
}
