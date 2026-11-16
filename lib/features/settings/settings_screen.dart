import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/cloud/backend_config.dart';
import '../../core/analytics/analytics.dart';
import '../../core/billing/billing_service.dart';
import '../../core/billing/trial_reminder.dart';
import '../../core/summary/apple_on_device_summarizer.dart';
import '../../core/summary/summary_service.dart';
import '../../core/transcription/transcriber.dart';
import '../../core/transcription/whisper_transcriber.dart';
import '../benchmark/benchmark_screen.dart';
import 'privacy_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SummaryEngine? _engine;
  bool? _appleAvailable;
  String? _appleReason;
  bool? _modelReady;
  int _versionTaps = 0;

  AppServices get _s => context.read<AppServices>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final engine = await _s.summaries.engine();
    final apple = _s.summaries.apple;
    final avail = await apple.isAvailable();
    final reason = (!avail && apple is AppleOnDeviceSummarizer)
        ? await apple.unavailableReason()
        : null;
    bool ready;
    try {
      ready = await _s.whisper.isReady();
    } catch (_) {
      ready = false;
    }
    if (!mounted) return;
    setState(() {
      _engine = engine;
      _appleAvailable = avail;
      _appleReason = reason;
      _modelReady = ready;
    });
  }

  Future<void> _downloadModel() async {
    final w = _s.whisper;
    try {
      await w.ensureReady();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _Header('Privacy'),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('What stays on your phone'),
            subtitle: const Text('Plain-language privacy explainer'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PrivacyScreen())),
          ),

          _Header('Summary engine'),
          if (_engine != null)
            for (final e in SummaryEngine.values)
              _engineTile(e),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'If the chosen engine is not available, Longnote makes the basic offline summary and tells you.',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),

          _Header('Speech-to-text model (on this phone)'),
          ValueListenableBuilder<WhisperChoice>(
            valueListenable: _s.whisperChoice,
            builder: (_, choice, _) => Column(children: [
              for (final c in WhisperChoice.values)
                RadioListTile<WhisperChoice>(
                  value: c,
                  // ignore: deprecated_member_use
                  groupValue: choice,
                  // ignore: deprecated_member_use
                  onChanged: (v) async {
                    if (v == null) return;
                    await _s.setWhisperChoice(v);
                    await _load();
                  },
                  title: Text(c.label),
                  subtitle: Text('${c.size} download, one time'),
                ),
            ]),
          ),
          ValueListenableBuilder<ModelStatus>(
            valueListenable: _s.whisper.status,
            builder: (_, st, _) {
              if (st.downloading) {
                return ListTile(
                  title: Text('Downloading model... ${(st.progress * 100).round()}%'),
                  subtitle: LinearProgressIndicator(value: st.progress == 0 ? null : st.progress),
                );
              }
              if (_modelReady == true || st.ready) {
                return const ListTile(
                  leading: Icon(Icons.check_circle_outline),
                  title: Text('Model is on this phone'),
                );
              }
              return ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Download model now'),
                subtitle: Text(st.error != null
                    ? 'Last try failed: ${st.error}'
                    : 'Otherwise it downloads before your first transcript. Wi-Fi recommended.'),
                onTap: _downloadModel,
              );
            },
          ),

          _Header('Plan'),
          ValueListenableBuilder<Entitlement>(
            valueListenable: _s.billing.entitlement,
            builder: (_, e, _) => _PlanTile(e: e),
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('Restore purchases'),
            onTap: () => _s.billing.restore(),
          ),
          const ListTile(
            leading: Icon(Icons.cancel_outlined),
            title: Text('How to cancel'),
            subtitle: Text(
                'iPhone Settings > your name > Subscriptions > Longnote > Cancel Subscription.'),
          ),

          _Header('Your data'),
          ListTile(
            leading: const Icon(Icons.list_alt),
            title: const Text('Usage log'),
            subtitle: const Text('The events this app records about itself. It never leaves your phone.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const _UsageLogScreen())),
          ),

          _Header('About'),
          ListTile(
            title: const Text('Longnote'),
            subtitle: const Text('Version 0.1.0 (test build)'),
            onTap: () {
              // Hidden: tap 7 times to open the Benchmark screen.
              if (++_versionTaps >= 7) {
                _versionTaps = 0;
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const BenchmarkScreen()));
              }
            },
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _engineTile(SummaryEngine e) {
    String? sub;
    var enabled = true;
    switch (e) {
      case SummaryEngine.auto:
        sub = _appleAvailable == true
            ? 'Uses Apple Intelligence on this phone.'
            : 'Uses the basic offline summary on this phone.';
      case SummaryEngine.apple:
        enabled = _appleAvailable == true;
        sub = enabled ? 'Nothing leaves your phone.' : (_appleReason ?? 'Not available on this phone.');
      case SummaryEngine.cloud:
        enabled = BackendConfig.current.isConfigured;
        sub = enabled
            ? 'Better summaries. Sends the transcript text (never audio) to our server and an AI provider. See Privacy.'
            : 'Not available in this build yet.';
      case SummaryEngine.local:
        sub = 'Picks important sentences. Works offline, but simpler.';
    }
    return RadioListTile<SummaryEngine>(
      value: e,
      // ignore: deprecated_member_use
      groupValue: _engine,
      // ignore: deprecated_member_use
      onChanged: enabled
          ? (v) async {
              if (v == null) return;
              await _s.summaries.setEngine(v);
              setState(() => _engine = v);
            }
          : null,
      title: Text(e.label),
      subtitle: Text(sub),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary)),
      );
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({required this.e});
  final Entitlement e;
  @override
  Widget build(BuildContext context) {
    final plan = e.planId == monthlyPlan.id ? monthlyPlan : annualPlan;
    final s = context.read<AppServices>();
    return switch (e.status) {
      EntitlementStatus.trial => ListTile(
          leading: const Icon(Icons.workspace_premium_outlined),
          title: Text('Free trial (${plan.periodWord}ly plan)'),
          subtitle: Text(
              'Trial ends ${formatDate(e.trialEndsAt!)}. Then ${plan.priceLabel} per ${plan.periodWord} unless you cancel.'),
        ),
      EntitlementStatus.active => ListTile(
          leading: const Icon(Icons.workspace_premium),
          title: Text('Subscribed (${plan.perPeriod})'),
          subtitle: e.renewsAt == null
              ? null
              : Text('Renews ${formatDate(e.renewsAt!)} for ${plan.priceLabel}.'),
        ),
      _ => FutureBuilder<int>(
          future: s.gate.freeUsed(),
          builder: (_, snap) => ListTile(
            leading: const Icon(Icons.card_giftcard),
            title: const Text('Free'),
            subtitle: Text((snap.data ?? 0) >= 1
                ? 'You have used your free recording.'
                : 'Your first recording is free, any length.'),
          ),
        ),
    };
  }
}

class _UsageLogScreen extends StatelessWidget {
  const _UsageLogScreen();
  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(title: const Text('Usage log')),
      body: FutureBuilder<List<LoggedEvent>>(
        future: s.analytics.recent(),
        builder: (_, snap) {
          final ev = snap.data;
          if (ev == null) return const Center(child: CircularProgressIndicator());
          if (ev.isEmpty) return const Center(child: Text('Nothing yet.'));
          return ListView.separated(
            itemCount: ev.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) => ListTile(
              dense: true,
              title: Text(ev[i].name),
              subtitle: Text('${ev[i].ts.toLocal()}'
                  '${ev[i].props.isEmpty ? '' : '\n${ev[i].props}'}'),
            ),
          );
        },
      ),
    );
  }
}
