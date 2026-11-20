import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/analytics/analytics.dart';
import '../../core/notes/languages.dart';
import '../../ui/widgets.dart';
import '../common/widgets.dart';

/// G2 Audio language (Figma 10:803): search, "Detect automatically",
/// suggested (English, Hindi, Hinglish, Spanish) and every language the
/// speech-to-text service supports. The [summary] variant picks the summary
/// language ("Same as audio" + names).
///
/// Saves the app setting and pops. With [initial] + [onPicked] it is a plain
/// picker (F2 import sheet): nothing is saved, the choice is returned.
class AudioLanguageScreen extends StatefulWidget {
  const AudioLanguageScreen({
    super.key,
    this.summary = false,
    this.initial,
    this.onPicked,
    this.backLabel = 'Settings',
  });

  /// true = "Summary language" variant.
  final bool summary;

  /// Picker mode: the current choice (code, or name for [summary]).
  final String? initial;
  final ValueChanged<String>? onPicked;
  final String backLabel;

  @override
  State<AudioLanguageScreen> createState() => _AudioLanguageScreenState();
}

class _Choice {
  const _Choice(this.value, this.label, {this.subtitle, this.search = ''});
  final String value;
  final String label;
  final String? subtitle;
  final String search;
}

class _AudioLanguageScreenState extends State<AudioLanguageScreen> {
  final _query = TextEditingController();
  String? _current;
  String _q = '';

  late final List<_Choice> _all;
  late final List<_Choice> _suggested;
  late final _Choice _first;

  @override
  void initState() {
    super.initState();
    if (widget.summary) {
      _first = const _Choice('same', 'Same as audio',
          subtitle: 'The summary uses the main language of the recording');
      _all = [
        for (final l in audioLanguages)
          _Choice(l.name, l.name, search: '${l.name} ${l.nativeName ?? ''} ${l.code}')
      ];
      _suggested = [
        for (final n in const ['English', 'Hindi', 'Spanish'])
          _all.firstWhere((c) => c.value == n)
      ];
    } else {
      _first = _Choice(autoDetect.code, autoDetect.name,
          subtitle: 'Best when people switch languages');
      _all = [
        for (final l in audioLanguages)
          _Choice(l.code, l.name, search: '${l.name} ${l.nativeName ?? ''} ${l.code}')
      ];
      final hinglishChoice = _Choice(hinglish.code, hinglish.name,
          search: 'hinglish hindi english');
      _suggested = [
        _all.firstWhere((c) => c.value == 'en'),
        _all.firstWhere((c) => c.value == 'hi'),
        hinglishChoice,
        _all.firstWhere((c) => c.value == 'es'),
      ];
    }
    _current = widget.initial;
    if (_current == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final st = context.read<AppServices>().settings;
        final v = widget.summary
            ? await st.summaryLanguage()
            : await st.audioLanguage();
        if (mounted) setState(() => _current = v);
      });
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _pick(String value) async {
    setState(() => _current = value);
    final picked = widget.onPicked;
    if (picked != null) {
      picked(value);
    } else {
      final s = context.read<AppServices>();
      final st = s.settings;
      if (widget.summary) {
        await st.setSummaryLanguage(value);
      } else {
        await st.setAudioLanguage(value);
      }
      s.analytics.log(AnalyticsEvent.settingChanged, props: {
        'setting': widget.summary ? 'summary_language' : 'audio_language',
        'value': _languageCode(value),
      });
    }
    if (mounted) Navigator.of(context).maybePop(value);
  }

  /// The summary setting stores a language name ("Spanish") or `same`;
  /// analytics gets the language code.
  String _languageCode(String value) {
    if (!widget.summary || value == 'same') return value;
    for (final l in audioLanguages) {
      if (l.name == value) return l.code;
    }
    return 'other';
  }

  List<_Choice> get _results {
    final q = _q.trim().toLowerCase();
    final pool = [..._suggested.where((c) => c.value == hinglish.code), ..._all];
    return [
      for (final c in pool)
        if (c.label.toLowerCase().contains(q) || c.search.toLowerCase().contains(q))
          c
    ];
  }

  Widget _row(_Choice c, {required bool first, required bool last}) =>
      LnCardSlice(
        first: first,
        last: last,
        child: LnCheckRow(
          label: c.label,
          subtitle: c.subtitle,
          checked: _current == c.value,
          onTap: () => _pick(c.value),
        ),
      );

  List<Widget> _section(String? label, List<_Choice> items) => [
        if (label != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 18),
              child: LnSectionLabel(label),
            ),
          ),
        SliverList.builder(
          itemCount: items.length,
          itemBuilder: (_, i) =>
              _row(items[i], first: i == 0, last: i == items.length - 1),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final searching = _q.trim().isNotEmpty;
    final results = searching ? _results : const <_Choice>[];
    return LnScaffold(
      backgroundColor: LnColors.paper,
      appBar: LnNavBar(
          title: widget.summary ? 'Summary language' : 'Audio language',
          backLabel: widget.backLabel),
      body: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 40),
            sliver: SliverMainAxisGroup(slivers: [
              SliverToBoxAdapter(
                child: LnSearchField(
                  controller: _query,
                  hint: 'Search 60+ languages',
                  onChanged: (v) => setState(() => _q = v),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
              if (searching) ...[
                if (results.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Center(
                          child: Text('No language matches “${_q.trim()}”.',
                              style: LnText.meta)),
                    ),
                  )
                else
                  ..._section(null, results),
              ] else ...[
                ..._section(null, [_first]),
                ..._section('Suggested', _suggested),
                ..._section('All languages', _all),
              ],
            ]),
          ),
        ],
      ),
    );
  }
}
