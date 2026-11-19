import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';

import '../../ui/widgets.dart';
import '../common/widgets.dart';
import '../note/kit.dart';

/// "What happens to your audio": plain-language privacy explainer. Keep this
/// TRUE: update it whenever data handling changes (BACKEND-API 6 is the
/// source for the deletion rules).
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget h(String s) => Padding(
          padding: const EdgeInsets.only(top: 22, bottom: 6),
          child: Text(s, style: LnText.rowTitle),
        );
    Widget p(String s) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(s, style: LnText.body.copyWith(color: LnColors.ink2)),
        );
    return LnScaffold(
      backgroundColor: LnColors.paper,
      appBar: const LnNavBar(title: 'Your audio', backLabel: 'Settings'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
        children: [
          h('On your phone'),
          p('Your recordings are saved on this phone while you record. Longnote never deletes them; only you can, from a note.'),
          p('Transcripts, summaries and Ask chats are kept on this phone too.'),
          h('Cloud transcription (the default)'),
          p('To make the transcript, a compressed copy of the audio is uploaded to our server and given to our speech-to-text provider (Soniox).'),
          p('As soon as the transcript is back, the audio is deleted from the provider and from our server. Anything left over is removed within 24 hours. The transcript is sent to your phone and then deleted from our server.'),
          h('On this phone'),
          p('If you choose “On this phone” in Settings → Transcription, the audio never leaves your phone. It is slower and has no speaker labels.'),
          h('Summaries and Ask'),
          p('To answer a question, and to write a summary when you use cloud transcription, the transcript text (never the audio) is sent to our server and to our AI provider (OpenAI). Our server does not keep it. OpenAI may keep it for up to 30 days to check for abuse, then deletes it. OpenAI does not train on data sent through its API.'),
          h('iCloud backup'),
          p('Your notes are part of your iPhone’s own iCloud backup if you have it turned on. That is Apple’s storage under your Apple ID, not ours.'),
          h('Usage analytics'),
          p('We count how the app is used (for example: a recording started, the paywall was shown, a trial started) with Amplitude, so we can fix problems. We also tell Meta when someone installs, starts a trial or subscribes, so we can see which of our ads work. Trial and subscription events are sent by our server when Apple tells us about them. We never read your advertising ID (IDFA).'),
          p('These events never include your audio, transcripts, summaries, note titles or questions. Turn them off in Settings → Share usage analytics.'),
          h('What we never do'),
          p('No account, no ads in the app, no selling data. A random ID (your Support ID, below) lets our server match your transcription jobs.'),
          h('Support ID'),
          p('Include this when you email support@novaralabs.in, for example to ask us to delete what our servers hold for you.'),
          const _SupportId(),
          h('Recording other people'),
          p('Tell people you are recording and get their consent. The laws differ by place.'),
        ],
      ),
    );
  }
}

/// The random anonymous ID (Supabase), shown so support can find a user's
/// server records (deletion by email). No network call.
class _SupportId extends StatelessWidget {
  const _SupportId();

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AppServices>().auth;
    return FutureBuilder<String?>(
      future: auth?.knownUserId(),
      builder: (context, snap) {
        final id = snap.data;
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          decoration: BoxDecoration(
            color: LnColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: LnColors.line),
          ),
          child: Row(children: [
            Expanded(
              child: SelectableText(
                id ?? 'Made after your first cloud transcription',
                style: LnText.meta.copyWith(color: LnColors.ink),
              ),
            ),
            if (id != null)
              LnPressable(
                semanticLabel: 'Copy Support ID',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: id));
                  if (context.mounted) showToast(context, 'Support ID copied');
                },
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: LnIcon(LnIcons.copy, size: 18),
                ),
              ),
          ]),
        );
      },
    );
  }
}
