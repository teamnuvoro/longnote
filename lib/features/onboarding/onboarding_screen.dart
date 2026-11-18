import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../app_services.dart';

/// Three short screens: what it does, the privacy promise, mic permission.
/// No sign-in, no account.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;
  String? _micMessage;

  /// Checking the App Store for an existing plan (up to a few seconds).
  bool _finishing = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (_finishing) return;
    final s = context.read<AppServices>();
    setState(() => _finishing = true);
    await s.kv.setBool(AppServices.kvOnboardingDone, true);
    // A fresh install can learn about an existing plan a few seconds late
    // (StoreKit syncs after install): ask again before showing the paywall.
    if (!s.billing.entitlement.value.isActive) await s.billing.refresh();
    if (!mounted) return;
    setState(() => _finishing = false);
    if (s.billing.entitlement.value.isActive) {
      // Already subscribed (reinstall / restored): no paywall.
      await s.kv.setBool(AppServices.kvFirstPaywallSeen, true);
      if (mounted) context.goNamed(R.notes);
      return;
    }
    // onboarding -> paywall (once) -> Notes
    context.goNamed(R.paywall, queryParameters: {'first': '1'});
  }

  Future<void> _askMic() async {
    // The recorder's own microphone source (a fake one in tests).
    final src = context.read<AppServices>().recorder.sourceFactory();
    bool ok;
    try {
      ok = await src.hasPermission(request: true);
    } catch (_) {
      ok = false;
    } finally {
      src.dispose();
    }
    if (ok) {
      await _finish();
    } else if (mounted) {
      setState(() => _micMessage =
          'No problem. You can turn the microphone on later in iPhone Settings > Longnote. Recording needs it.');
    }
  }

  void _next() => _pages.nextPage(
      duration: const Duration(milliseconds: 300), curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    final pages = [
      const _Page(
        icon: Icons.graphic_eq,
        title: 'Record for hours.\nGet clear notes.',
        body:
            'Tap one button to record a meeting, lecture or talk. It keeps going with the screen locked. '
            'Afterwards you get a transcript and a summary with key points, decisions and action items.',
      ),
      const _Page(
        icon: Icons.lock_outline,
        title: 'Where your audio goes',
        body:
            'Audio is saved on this phone while you record, so a locked screen or a closed app never loses it.\n\n'
            'To write the transcript, Longnote sends the audio to our speech-to-text provider. '
            'It is deleted from their servers and ours as soon as the transcript is back; the original stays on your phone until you delete it.\n\n'
            'Prefer nothing to leave your phone? Choose "On this phone" in Settings › Transcription. It is slower and has no speaker labels.\n\n'
            'No account. No ads. Please ask people before you record them.',
      ),
      _Page(
        icon: Icons.mic_none,
        title: 'Allow the microphone',
        body:
            'Longnote needs the microphone to record. It only listens while you are recording, and the red indicator shows when.',
        footer: _micMessage,
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _page = i),
                children: pages,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                3,
                (i) => Container(
                  margin: const EdgeInsets.all(4),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == _page
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _finishing
                      ? null
                      : _page < 2
                          ? _next
                          : (_micMessage == null ? _askMic : _finish),
                  child: _finishing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_page < 2
                          ? 'Continue'
                          : (_micMessage == null
                              ? 'Allow microphone'
                              : 'Continue')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.icon, required this.title, required this.body, this.footer});
  final IconData icon;
  final String title;
  final String body;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 64, 28, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 28),
          Text(title, style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          Text(body, style: t.bodyLarge?.copyWith(height: 1.45)),
          if (footer != null) ...[
            const SizedBox(height: 16),
            Text(footer!, style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
