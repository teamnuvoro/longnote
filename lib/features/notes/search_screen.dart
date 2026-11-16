import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../app_services.dart';
import '../../core/notes/search.dart';
import '../../ui/widgets.dart';
import '../note/kit.dart';

enum SearchScope { all, titles, summaries, transcripts }

class _Hit {
  _Hit(this.result, this.hit);
  final NoteSearchResult result;
  final SearchHit hit;
}

/// B3 Search (Figma 3:243): titles, summaries and transcripts as you type
/// (SQLite FTS). Each hit says where it came from; a transcript hit opens
/// the note at that moment.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.initialQuery});
  final String? initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final AppServices _s = context.read<AppServices>();
  late final _ctl = TextEditingController(text: widget.initialQuery ?? '');
  Timer? _debounce;
  SearchScope _scope = SearchScope.all;
  List<NoteSearchResult> _results = const [];
  Map<String, int> _durations = const {};
  Map<String, Map<String, String>> _names = const {};
  int _seq = 0;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    if (_ctl.text.isNotEmpty) _run(_ctl.text);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () => _run(v));
  }

  Future<void> _run(String q) async {
    final seq = ++_seq;
    if (q.trim().isEmpty) {
      setState(() {
        _results = const [];
        _searched = false;
      });
      return;
    }
    final results = await _s.search.search(q);
    final durations = <String, int>{};
    final names = <String, Map<String, String>>{};
    for (final r in results) {
      final n = await _s.repo.get(r.recordingId);
      durations[r.recordingId] = n?.durationMs ?? 0;
      if (r.hits.any((h) => h.kind == SearchHitKind.transcript && h.speaker != null)) {
        names[r.recordingId] = await _s.speakers.names(r.recordingId);
      }
    }
    if (!mounted || seq != _seq) return;
    setState(() {
      _results = results;
      _durations = durations;
      _names = names;
      _searched = true;
    });
  }

  bool _inScope(SearchHit h) => switch (_scope) {
        SearchScope.all => true,
        SearchScope.titles => h.kind == SearchHitKind.title,
        SearchScope.summaries => h.kind == SearchHitKind.summary,
        SearchScope.transcripts => h.kind == SearchHitKind.transcript,
      };

  void _openHit(_Hit h) {
    final id = h.hit.recordingId;
    if (h.hit.kind == SearchHitKind.transcript && h.hit.startMs != null) {
      context.pushNamed(R.note,
          pathParameters: {'id': id},
          queryParameters: {'tab': 'transcript', 'at': '${h.hit.startMs}'});
    } else {
      context.pushNamed(R.note, pathParameters: {'id': id});
    }
  }

  @override
  Widget build(BuildContext context) {
    final hits = <_Hit>[
      for (final r in _results)
        for (final h in r.hits)
          if (_inScope(h)) _Hit(r, h)
    ];
    final notes = hits.map((h) => h.result.recordingId).toSet().length;
    return Scaffold(
      backgroundColor: LnColors.paper,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(slivers: [
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
            sliver: SliverList.list(children: [
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 16),
                child: Row(children: [
                  Expanded(child: _Field(controller: _ctl, onChanged: _onChanged)),
                  const SizedBox(width: 12),
                  LnPressable(
                    onPressed: () =>
                        context.canPop() ? context.pop() : context.goNamed(R.notes),
                    semanticLabel: 'Cancel',
                    child: Text('Cancel',
                        style: LnText.headline.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            fontVariations: const [FontVariation('wght', 500)])),
                  ),
                ]),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final s in SearchScope.values) ...[
                    if (s.index > 0) const SizedBox(width: 8),
                    _ScopeChip(
                      label: switch (s) {
                        SearchScope.all => 'All',
                        SearchScope.titles => 'Titles',
                        SearchScope.summaries => 'Summaries',
                        SearchScope.transcripts => 'Transcripts',
                      },
                      selected: s == _scope,
                      onTap: () => setState(() => _scope = s),
                    ),
                  ],
                ]),
              ),
              const SizedBox(height: 16),
              if (_searched)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(
                      hits.isEmpty
                          ? 'No matches'
                          : '$notes ${notes == 1 ? 'note' : 'notes'} · ${hits.length} ${hits.length == 1 ? 'match' : 'matches'}',
                      style: LnText.sectionLabel),
                ),
            ]),
          ),
          if (hits.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
              sliver: DecoratedSliver(
                decoration: BoxDecoration(
                  color: LnColors.card,
                  borderRadius: BorderRadius.circular(LnRadius.card),
                  border: Border.all(color: LnColors.line),
                ),
                sliver: SliverList.builder(
                  itemCount: hits.length,
                  itemBuilder: (context, i) => Column(children: [
                    if (i > 0)
                      const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: LnHairline()),
                    _HitRow(
                      hit: hits[i],
                      durationMs: _durations[hits[i].result.recordingId] ?? 0,
                      speakerName: _speakerName(hits[i]),
                      onTap: () => _openHit(hits[i]),
                    ),
                  ]),
                ),
              ),
            ),
          SliverToBoxAdapter(
              child: SizedBox(height: 40 + MediaQuery.paddingOf(context).bottom)),
        ]),
      ),
    );
  }

  String? _speakerName(_Hit h) {
    final k = h.hit.speaker;
    if (k == null) return null;
    return _names[h.result.recordingId]?[k] ?? 'Speaker $k';
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: LnColors.card,
          borderRadius: BorderRadius.circular(LnRadius.search),
          border: Border.all(color: LnColors.ink),
        ),
        child: Row(children: [
          const LnIcon(LnIcons.search, size: 18, color: LnColors.ink),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: LnText.body.copyWith(height: 1.2),
              cursorColor: LnColors.ink,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Search notes and transcripts',
                hintStyle: LnText.placeholder,
              ),
            ),
          ),
        ]),
      );
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        semanticLabel: label,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? LnColors.ink : LnColors.card,
            borderRadius: BorderRadius.circular(LnRadius.pill),
            border: Border.all(color: selected ? LnColors.ink : LnColors.line),
          ),
          child: Text(label,
              style: LnText.caption
                  .copyWith(color: selected ? LnColors.card : LnColors.ink)),
        ),
      );
}

class _HitRow extends StatelessWidget {
  const _HitRow({
    required this.hit,
    required this.durationMs,
    required this.onTap,
    this.speakerName,
  });
  final _Hit hit;
  final int durationMs;
  final String? speakerName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final h = hit.hit;
    final where = switch (h.kind) {
      SearchHitKind.title => 'Title',
      SearchHitKind.summary => 'Summary',
      SearchHitKind.transcript => [
          'Transcript',
          if (h.startMs != null) clockText(h.startMs!),
          ?speakerName,
        ].join(' · '),
    };
    final base = LnText.preview;
    final strong = LnText.preview.copyWith(
        color: LnColors.ink,
        fontWeight: FontWeight.w600,
        fontVariations: const [FontVariation('wght', 600)],
        decoration: TextDecoration.underline);
    final snippet = h.kind == SearchHitKind.transcript ? '“${h.snippet}”' : h.snippet;
    return LnPressable(
      onPressed: onTap,
      pressedOpacity: 0.7,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: h.kind == SearchHitKind.title
                  ? Text.rich(
                      TextSpan(
                          children: markedSpans(h.snippet, LnText.rowTitle,
                              LnText.rowTitle.copyWith(
                                  decoration: TextDecoration.underline))),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis)
                  : Text(hit.result.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LnText.rowTitle),
            ),
            const SizedBox(width: 8),
            Text(clockText(durationMs), style: LnText.monoSmall),
          ]),
          if (h.kind != SearchHitKind.title) ...[
            const SizedBox(height: 6),
            Text(where, style: LnText.chip.copyWith(color: LnColors.ink3)),
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(children: markedSpans(snippet, base, strong)),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ]),
      ),
    );
  }
}
