import 'package:flutter/material.dart';

import '../../ui/widgets.dart';
import '../common/widgets.dart';

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
          p('To write a summary or answer a question, the transcript text (never the audio) is sent to our server and to our AI provider (OpenAI). Neither keeps it: the answer comes back to your phone. OpenAI does not train on data sent through its API.'),
          h('iCloud backup'),
          p('Recordings are included in your iPhone’s iCloud backup unless you turn that off in Settings → Transcription.'),
          h('What we never do'),
          p('No account, no ads, no tracking SDKs, no selling data. A hidden user id lets our server apply fair-use limits.'),
          h('Recording other people'),
          p('Tell people you are recording and get their consent. The laws differ by place.'),
        ],
      ),
    );
  }
}
