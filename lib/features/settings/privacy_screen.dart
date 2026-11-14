import 'package:flutter/material.dart';

/// Plain-language privacy explainer. Keep this TRUE: update it whenever data
/// handling changes.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget h(String s) => Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 6),
          child: Text(s, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        );
    Widget p(String s) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(s, style: t.bodyLarge?.copyWith(height: 1.45)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          h('What stays on your phone'),
          p('Your audio. It is saved on this phone while you record and never uploaded by Longnote.'),
          p('Your transcripts. Speech-to-text runs on this phone.'),
          p('Your summaries, when you use "Automatic", "Apple Intelligence" or "Basic offline summary". Apple Intelligence runs on the phone too.'),
          p('A small usage log (for example "recording started", "export"). It stays on the phone; you can read it in Settings > Usage log.'),
          h('What goes over the internet'),
          p('Once: the speech-to-text model file is downloaded from Hugging Face (a public model host). No audio or text is sent to download it.'),
          p('Only if you choose "Cloud" as the summary engine: the transcript TEXT (never the audio) is sent to our server, which passes it to Anthropic (the company that makes the Claude AI model) to write the summary. The summary is sent back to your phone. Our server does not store the transcript.'),
          p('Anthropic\'s commercial terms say it does not train its models on this data. It may keep it for a limited time for safety checks, as its policy describes.'),
          h('What we never do'),
          p('No account, no sign-in, no ads, no tracking SDKs, no selling data.'),
          h('Payments'),
          p('Subscriptions go through Apple. We never see your card details.'),
          h('Recording other people'),
          p('Please tell people you are recording and get their consent. The laws differ by place.'),
          h('Deleting'),
          p('Delete a recording from its share menu: the audio, transcript and summary are removed from this phone. Deleting the app removes everything.'),
        ],
      ),
    );
  }
}
