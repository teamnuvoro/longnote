import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../app_services.dart';
import '../../core/models/recording.dart';
import '../../core/notes/languages.dart';
import '../../core/summary/summary_style.dart';
import '../../ui/widgets.dart';

/// G1 Settings (Figma 10:643). MINIMAL version wired to AppSettings: the
/// screens session finishes the plan card copy and the Help rows.
/// "Advanced" opens the v0.1 settings screen (engines, models, usage log,
/// hidden benchmark: tap the version 7 times).
class SettingsHomeScreen extends StatefulWidget {
  const SettingsHomeScreen({super.key});
  @override
  State<SettingsHomeScreen> createState() => _SettingsHomeScreenState();
}

class _SettingsHomeScreenState extends State<SettingsHomeScreen> {
  int _taps = 0;

  Future<_Values> _load(AppServices s) async => _Values(
        audio: audioLanguageFor(await s.settings.audioLanguage()).name,
        summary: await s.settings.summaryLanguage(),
        style: await s.settings.defaultStyle(),
        speakers: await s.settings.speakerLabels(),
        mode: await s.settings.transcriptionMode(),
      );

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      backgroundColor: LnColors.paper,
      body: SafeArea(
        bottom: false,
        child: FutureBuilder<_Values>(
          future: _load(s),
          builder: (context, snap) {
            final v = snap.data;
            return ListView(
              padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
              children: [
                const LnLargeTitle('Settings'),
                _PlanCard(onManage: () => context.pushNamed(R.plan)),
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
                    onChanged: (x) async {
                      await s.settings.setSpeakerLabels(x);
                      setState(() {});
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
                          : (v.mode == TranscriptionMode.cloud ? 'Cloud' : 'On this phone'),
                      onTap: () => _open(R.transcription)),
                  LnListRow(
                      icon: LnIcons.shield,
                      label: 'What happens to your audio',
                      onTap: () => _open(R.privacy)),
                ]),
                const SizedBox(height: 18),
                const LnSectionLabel('Help'),
                LnCardGroup.settings(children: [
                  LnListRow(icon: LnIcons.mail, label: 'Contact us', onTap: _todo),
                  LnListRow(icon: LnIcons.bulb, label: 'Suggest a feature', onTap: _todo),
                  LnListRow(icon: LnIcons.star, label: 'Rate Longnote', onTap: _todo),
                  LnListRow(icon: LnIcons.more, label: 'Advanced', onTap: () => _open(R.advanced)),
                ]),
                const SizedBox(height: 18),
                GestureDetector(
                  onTap: () {
                    if (++_taps >= 7) {
                      _taps = 0;
                      context.pushNamed(R.benchmark);
                    }
                  },
                  child: Center(child: Text('Longnote v1 (build preview)', style: LnText.meta)),
                ),
                const SizedBox(height: 40),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _open(String route) async {
    await context.pushNamed(route);
    if (mounted) setState(() {});
  }

  void _todo() => ScaffoldMessenger.of(context)
      .showSnackBar(const SnackBar(content: Text('Coming in the next build.')));
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
}

/// Dark plan card at the top of G1.
class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.onManage});
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final e = s.billing.entitlement.value;
    final title = e.isActive ? 'Longnote · subscribed' : 'Longnote · free';
    final sub = e.trialEndsAt != null
        ? 'Free trial until ${e.trialEndsAt!.month}/${e.trialEndsAt!.day}.'
        : (e.isActive ? 'Thank you for subscribing.' : 'Your first recording is free.');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
          color: LnColors.ink, borderRadius: BorderRadius.circular(LnRadius.card)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: LnText.rowTitle.copyWith(color: LnColors.card)),
            const SizedBox(height: 3),
            Text(sub, style: LnText.meta.copyWith(color: LnColors.nightText2)),
          ]),
        ),
        const SizedBox(width: 14),
        LnPillButton(label: 'Manage', style: LnPillStyle.onDark, onPressed: onManage),
      ]),
    );
  }
}
