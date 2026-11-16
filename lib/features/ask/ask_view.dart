import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/routes.dart';
import '../../app_services.dart';
import '../../core/cloud/api_error.dart';
import '../../core/models/recording.dart';
import '../../core/notes/chat.dart';
import '../../core/recording/recording_repository.dart';
import '../../ui/widgets.dart';
import '../common/dates.dart';
import '../common/external.dart';
import 'last_note.dart';

/// Starter questions (E1).
const askStarters = [
  'What did we decide?',
  'List action items and who owns them',
  'Draft a follow-up email',
  'What numbers came up?',
  'What is still open?',
];

/// Follow-up chips under the last answer (E2).
List<String> followUpsFor(String question, {bool found = true}) {
  if (!found) return const ['Summarize the note', 'What did we decide?'];
  return switch (question) {
    'Draft a follow-up email' => const ['Make it shorter', 'More formal'],
    'What did we decide?' => const ['Who agreed to it?', 'What is still open?'],
    'List action items and who owns them' =>
      const ['Which are due soon?', 'Draft a follow-up email'],
    'What numbers came up?' => const ['Make it a table', 'What did we decide?'],
    'What is still open?' => const ['Who should follow up?', 'Draft a follow-up email'],
    _ => const ['Tell me more', 'Draft a follow-up email'],
  };
}

/// Plain words for an Ask failure.
String askErrorText(Object e) {
  if (e is ApiException) {
    if (e.code == 'limit_reached') {
      return 'You have used today’s questions. Ask again after the daily reset (midnight UTC).';
    }
    if (e.code == networkErrorCode) return _offline;
    return e.userMessage;
  }
  if (isNetworkError(e)) return _offline;
  return 'Something went wrong. Try again.';
}

const _offline = 'You are offline. Connect to the internet and try again.';

/// E1 + E2 (Figma 9:364, 9:465): note picker, starter questions, then the
/// chat with source chips. Used by the Ask tab and by /ask/:id (opened from a
/// note, [noteId] preselected, with a back button).
class AskView extends StatefulWidget {
  const AskView({super.key, this.noteId, this.onBack});
  final String? noteId;

  /// Set when pushed (from a note): shows a back bar.
  final VoidCallback? onBack;

  @override
  State<AskView> createState() => _AskViewState();
}

class _AskViewState extends State<AskView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  Recording? _note;
  bool _resolved = false;
  List<ChatMessage> _msgs = const [];
  Map<String, int> _colors = const {};

  /// A question being answered right now.
  String? _pending;

  /// Last failure: the question it was for and the words to show.
  String? _errorQ;
  String? _error;

  late final RecordingRepository _repo;
  AppServices get _s => context.read<AppServices>();

  @override
  void initState() {
    super.initState();
    _repo = context.read<RecordingRepository>();
    _repo.addListener(_onRepo);
    _input.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve(widget.noteId));
  }

  @override
  void dispose() {
    _repo.removeListener(_onRepo);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// A note may become ready while Ask is open with nothing picked.
  void _onRepo() {
    if (_resolved && _note == null && _pending == null) _resolve(null);
  }

  Future<void> _resolve(String? requested) async {
    if (!mounted) return;
    final n = await pickAskNote(_s, requested: requested);
    await _select(n, remember: requested != null);
  }

  Future<void> _select(Recording? n, {bool remember = true}) async {
    if (!mounted) return;
    var msgs = const <ChatMessage>[];
    var colors = const <String, int>{};
    if (n != null) {
      if (remember) _s.kv.set(kvLastOpenedNote, n.id);
      msgs = await _s.chat.list(n.id);
      colors = {for (final sp in await _s.speakers.list(n.id)) sp.name: sp.colorIndex};
    }
    if (!mounted) return;
    setState(() {
      _note = n;
      _msgs = msgs;
      _colors = colors;
      _resolved = true;
      _error = null;
      _errorQ = null;
    });
    _toEnd();
  }

  Future<void> _choose() async {
    final id = await context.pushNamed<String>(R.askChoose);
    if (id == null || !mounted) return;
    await _select(await _s.repo.get(id));
  }

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic);
      }
    });
  }

  bool get _canSend =>
      _note != null && askable(_note!) && _pending == null;

  Future<void> _send(String text, {bool retry = false}) async {
    final q = text.trim();
    final note = _note;
    if (q.isEmpty || note == null || !_canSend) return;
    final ask = _s.ask;
    _input.clear();
    setState(() {
      _pending = q;
      _error = null;
      _errorQ = null;
    });
    _toEnd();
    try {
      if (ask == null) {
        throw StateError('no backend');
      }
      final stored = _msgs.isNotEmpty &&
          _msgs.last.role == ChatRole.user &&
          _msgs.last.text == q;
      if (retry && stored) {
        // The question is already saved: only ask for the answer again.
        await ask.answer(note.id, q, _msgs.sublist(0, _msgs.length - 1));
      } else {
        await ask.ask(note.id, q);
      }
      _error = null;
    } catch (e) {
      _errorQ = q;
      _error = ask == null
          ? 'Ask needs our server, which is not set up in this build.'
          : askErrorText(e);
    }
    final msgs = await _s.chat.list(note.id);
    if (!mounted) return;
    setState(() {
      _msgs = msgs;
      _pending = null;
    });
    _toEnd();
  }

  void _openSource(AskSource src) {
    final n = _note;
    if (n == null) return;
    context.pushNamed(R.note,
        pathParameters: {'id': n.id},
        queryParameters: {'tab': 'transcript', 'at': '${src.startMs}'});
  }

  @override
  Widget build(BuildContext context) {
    final chat = _msgs.isNotEmpty || _pending != null || _error != null;
    return Column(children: [
      if (widget.onBack != null) LnTopBar(backLabel: 'Back', onBack: widget.onBack),
      Expanded(
        child: SafeArea(
          top: widget.onBack == null,
          bottom: false,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            child: chat ? _chat() : _start(),
          ),
        ),
      ),
      _Composer(
        controller: _input,
        focus: _focus,
        enabled: _canSend,
        hint: _note == null ? 'Pick a note first' : 'Ask about this note…',
        onSend: () => _send(_input.text),
      ),
    ]);
  }

  // ---- E1 ------------------------------------------------------------------
  Widget _start() {
    final n = _note;
    final ready = n != null && askable(n);
    return ListView(
      key: const ValueKey('ask-start'),
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: LnSpace.page),
      children: [
        const LnLargeTitle('Ask'),
        _NotePicker(note: n, resolved: _resolved, onTap: _choose),
        const SizedBox(height: 28),
        Text(
          n == null && _resolved
              ? 'Record or import a note first. When its transcript is ready, you can ask anything about it here.'
              : 'Ask anything about this note. Answers come only from what was said, with the moment they came from.',
          style: LnText.bullet.copyWith(color: LnColors.ink2, height: 22 / 15),
        ),
        const SizedBox(height: 20),
        for (final q in askStarters)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _Starter(text: q, onTap: ready ? () => _send(q) : null),
          ),
        const SizedBox(height: 12),
      ],
    );
  }

  // ---- E2 ------------------------------------------------------------------
  Widget _chat() {
    final items = <Widget>[];
    for (var i = 0; i < _msgs.length; i++) {
      final m = _msgs[i];
      final last = i == _msgs.length - 1;
      if (m.role == ChatRole.user) {
        // An unanswered question that failed shows its error below.
        items.add(_UserBubble(m.text));
        items.add(const SizedBox(height: 14));
        if (last && _error != null && _errorQ == m.text && _pending == null) {
          items.add(_ErrorCard(
              text: _error!, onRetry: () => _send(m.text, retry: true)));
          items.add(const SizedBox(height: 14));
        }
      } else {
        String? q;
        for (var j = i - 1; j >= 0; j--) {
          if (_msgs[j].role == ChatRole.user) {
            q = _msgs[j].text;
            break;
          }
        }
        items.add(_AnswerCard(
          message: m,
          colors: _colors,
          onSource: _openSource,
        ));
        items.add(const SizedBox(height: 12));
        if (last && _pending == null) {
          items.add(Wrap(spacing: 8, runSpacing: 8, children: [
            for (final f in followUpsFor(q ?? '', found: m.found ?? true))
              LnPillChip(label: f, onTap: _canSend ? () => _send(f) : null),
          ]));
          items.add(const SizedBox(height: 12));
        }
      }
    }
    if (_pending != null) {
      if (_msgs.isEmpty || _msgs.last.text != _pending || _msgs.last.role != ChatRole.user) {
        items.add(_UserBubble(_pending!));
        items.add(const SizedBox(height: 14));
      }
      items.add(const _Thinking());
    }
    if (_error != null && (_msgs.isEmpty || _msgs.last.role != ChatRole.user)) {
      if (_errorQ != null) {
        items.add(_UserBubble(_errorQ!));
        items.add(const SizedBox(height: 14));
      }
      items.add(_ErrorCard(
          text: _error!,
          onRetry: _errorQ == null ? null : () => _send(_errorQ!)));
    }
    return Column(key: const ValueKey('ask-chat'), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(LnSpace.page, 8, LnSpace.page, 12),
        child: Row(children: [
          Expanded(
              child: Text('Ask',
                  style: LnText.largeTitle.copyWith(fontSize: 26))),
          _NoteChip(title: _note?.title ?? 'Choose a note', onTap: _choose),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(LnSpace.page, 0, LnSpace.page, 16),
          itemCount: items.length,
          itemBuilder: (_, i) => items[i],
        ),
      ),
    ]);
  }
}

// ---- pieces ----------------------------------------------------------------

class _NotePicker extends StatelessWidget {
  const _NotePicker(
      {required this.note, required this.resolved, required this.onTap});
  final Recording? note;
  final bool resolved;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        pressedOpacity: 0.7,
        semanticLabel: 'Choose a note',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: LnColors.card,
            borderRadius: BorderRadius.circular(LnRadius.actionCard),
            border: Border.all(color: LnColors.line),
          ),
          child: Row(children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: LnColors.fill,
                  borderRadius: BorderRadius.circular(LnRadius.iconButton)),
              child: const LnIcon(LnIcons.document, size: 17),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Asking about',
                    style: LnText.chip.copyWith(color: LnColors.ink3)),
                const SizedBox(height: 1),
                Text(
                    note?.title ?? (resolved ? 'No notes yet' : ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: LnText.rowTitleSmall),
              ]),
            ),
            const SizedBox(width: 12),
            const LnIcon(LnIcons.chevronDown, size: 18, color: LnColors.ink2),
          ]),
        ),
      );
}

class _NoteChip extends StatelessWidget {
  const _NoteChip({required this.title, required this.onTap});
  final String title;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        semanticLabel: 'Choose a note',
        child: Container(
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: LnColors.card,
            borderRadius: BorderRadius.circular(LnRadius.pill),
            border: Border.all(color: LnColors.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const LnIcon(LnIcons.document, size: 13),
            const SizedBox(width: 6),
            Flexible(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LnText.smallButton),
            ),
            const SizedBox(width: 6),
            const LnIcon(LnIcons.chevronDown, size: 13, color: LnColors.ink2),
          ]),
        ),
      );
}

class _Starter extends StatelessWidget {
  const _Starter({required this.text, required this.onTap});
  final String text;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        pressedOpacity: 0.6,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: LnColors.card,
            borderRadius: BorderRadius.circular(LnRadius.actionCard),
            border: Border.all(color: LnColors.line),
          ),
          child: Row(children: [
            const LnIcon(LnIcons.sparkle, size: 15, color: LnColors.ink2),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: LnText.rowLabel)),
            const SizedBox(width: 10),
            const LnIcon(LnIcons.chevronRight, size: 16, color: LnColors.ink3),
          ]),
        ),
      );
}

class _UserBubble extends StatelessWidget {
  const _UserBubble(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              color: LnColors.ink,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(18),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: Text(text,
                style: LnText.rowLabel.copyWith(color: LnColors.card)),
          ),
        ),
      );
}

const _answerRadius = BorderRadius.only(
  topLeft: Radius.circular(6),
  topRight: Radius.circular(18),
  bottomLeft: Radius.circular(18),
  bottomRight: Radius.circular(18),
);

class _AnswerCard extends StatelessWidget {
  const _AnswerCard(
      {required this.message, required this.colors, required this.onSource});
  final ChatMessage message;
  final Map<String, int> colors;
  final ValueChanged<AskSource> onSource;

  @override
  Widget build(BuildContext context) {
    var text = message.text.trim();
    String? subject;
    if (text.startsWith('Subject:')) {
      final nl = text.indexOf('\n');
      subject = nl < 0 ? text : text.substring(0, nl).trim();
      text = nl < 0 ? '' : text.substring(nl + 1).trim();
    }
    final notFound = message.found == false;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: LnColors.card,
        borderRadius: _answerRadius,
        border: Border.all(color: LnColors.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (notFound) ...[
          Text('Not in this recording', style: LnText.overline),
          const SizedBox(height: 6),
        ],
        if (subject != null) ...[
          Text(subject,
              style: LnText.rowLabel.copyWith(
                  fontWeight: FontWeight.w600,
                  fontVariations: const [FontVariation('wght', 600)])),
          if (text.isNotEmpty) const SizedBox(height: 10),
        ],
        if (text.isNotEmpty)
          SelectableText(text, style: LnText.turn),
        if (message.sources.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('From the note',
              style: LnText.chip.copyWith(color: LnColors.ink3)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final src in message.sources)
              _SourceChip(
                  source: src,
                  color: LnSpeakerColors.of(
                      colors[src.speaker] ?? src.speaker.hashCode),
                  onTap: () => onSource(src)),
          ]),
        ],
        const SizedBox(height: 10),
        Row(children: [
          _TextAction(
            icon: LnIcons.copy,
            label: 'Copy',
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: message.text));
              if (context.mounted) showNote(context, 'Copied');
            },
          ),
          const SizedBox(width: 16),
          _TextAction(
            icon: LnIcons.share,
            label: 'Share',
            onTap: () => External.shareText(message.text),
          ),
        ]),
      ]),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip(
      {required this.source, required this.color, required this.onTap});
  final AskSource source;
  final Color color;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        semanticLabel:
            'Open the transcript at ${clockPosition(source.startMs)}, ${source.speaker}',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: LnColors.fill,
              borderRadius: BorderRadius.circular(LnRadius.segment)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(source.speaker,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LnText.chip.copyWith(color: LnColors.ink)),
            ),
            const SizedBox(width: 5),
            Text(clockPosition(source.startMs), style: LnText.monoTiny),
          ]),
        ),
      );
}

class _TextAction extends StatelessWidget {
  const _TextAction(
      {required this.icon, required this.label, required this.onTap});
  final LnIcons icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => LnPressable(
        onPressed: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            LnIcon(icon, size: 15, color: LnColors.ink2),
            const SizedBox(width: 6),
            Text(label, style: LnText.caption),
          ]),
        ),
      );
}

class _Thinking extends StatelessWidget {
  const _Thinking();
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: LnColors.card,
          borderRadius: _answerRadius,
          border: Border.all(color: LnColors.line),
        ),
        child: Row(children: [
          const CupertinoActivityIndicator(radius: 8),
          const SizedBox(width: 10),
          Text('Reading the transcript…', style: LnText.meta),
        ]),
      );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.text, this.onRetry});
  final String text;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: LnColors.attentionTint,
          borderRadius: _answerRadius,
        ),
        child: Row(children: [
          const LnIcon(LnIcons.alert, size: 18, color: LnColors.attention),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style: LnText.meta.copyWith(color: LnColors.ink))),
          if (onRetry != null) ...[
            const SizedBox(width: 10),
            LnSmallButton(label: 'Try again', onPressed: onRetry),
          ],
        ]),
      );
}

/// Composer above the tab bar (E1/E2): white pill field + round send button.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.enabled,
    required this.hint,
    required this.onSend,
  });
  final TextEditingController controller;
  final FocusNode focus;
  final bool enabled;
  final String hint;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final hasText = controller.text.trim().isNotEmpty;
    final canSend = enabled && hasText;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: LnColors.card,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: LnColors.line),
            ),
            child: TextField(
              key: const ValueKey('ask-input'),
              controller: controller,
              focusNode: focus,
              enabled: enabled || hasText,
              minLines: 1,
              maxLines: 5,
              maxLength: 1000,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              style: LnText.rowValue.copyWith(color: LnColors.ink, height: 1.2),
              cursorColor: LnColors.ink,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                counterText: '',
                hintText: hint,
                hintStyle: LnText.rowValue.copyWith(color: LnColors.ink3, height: 1.2),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: canSend ? onSend : null,
          child: Semantics(
          button: true,
          enabled: canSend,
          label: 'Send',
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: canSend ? LnColors.ink : LnColors.fill,
                shape: BoxShape.circle),
            child: LnIcon(LnIcons.arrowUp,
                size: 20, color: canSend ? LnColors.card : LnColors.ink3),
          ),
        )),
      ]),
    );
  }
}
