import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/models/recording.dart';
import '../../core/util/clock.dart';
import '../../ui/widgets.dart';
import '../common/dates.dart';
import '../common/screen_clock.dart';
import '../common/widgets.dart';
import 'last_note.dart';

/// E3 Choose a note (Figma 9:569): search + every note; notes still being
/// processed are shown but disabled. Pops with the chosen note id.
class ChooseNoteSheet extends StatefulWidget {
  const ChooseNoteSheet({super.key});
  @override
  State<ChooseNoteSheet> createState() => _ChooseNoteSheetState();
}

class _ChooseNoteSheetState extends State<ChooseNoteSheet> {
  List<Recording>? _notes;
  String? _current;
  String _q = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final s = context.read<AppServices>();
      final notes = [
        for (final n in await s.repo.all())
          if (!n.status.isLive) n
      ];
      final current = await s.kv.get(kvLastOpenedNote);
      if (mounted) {
        setState(() {
          _notes = notes;
          _current = current;
        });
      }
    });
  }

  String _sub(Recording n) {
    final day = dayLabel(n.createdAt, screenNow());
    if (askable(n)) return '$day · ${formatDuration(n.duration)}';
    if (n.processingStatus.inProgress) return '$day · processing…';
    if (n.processingStatus == ProcessingStatus.failed) {
      return '$day · no transcript yet';
    }
    return '$day · waiting to be transcribed';
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final notes = [
      for (final n in _notes ?? const <Recording>[])
        if (q.isEmpty || n.title.toLowerCase().contains(q)) n
    ];
    final maxH = MediaQuery.sizeOf(context).height * 0.86;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: LnPlainSheet(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [
              Expanded(child: Text('Choose a note', style: LnText.noteTitle)),
              LnPressable(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text('Cancel',
                    style: LnText.sheetRowLabel.copyWith(color: LnColors.ink2)),
              ),
            ]),
          ),
          LnSearchField(
            hint: 'Search notes',
            onChanged: (v) => setState(() => _q = v),
          ),
          const SizedBox(height: 12),
          if (_notes != null && notes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                  _notes!.isEmpty
                      ? 'No notes yet. Record or import one first.'
                      : 'No note matches “${_q.trim()}”.',
                  style: LnText.meta),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: notes.length,
                itemBuilder: (_, i) {
                  final n = notes[i];
                  return LnCardSlice(
                    first: i == 0,
                    last: i == notes.length - 1,
                    dividerInset: 16,
                    child: LnCheckRow(
                      label: n.title,
                      subtitle: _sub(n),
                      labelStyle: LnText.rowTitleSmall,
                      subtitleColor: LnColors.ink3,
                      checked: n.id == _current,
                      enabled: askable(n),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      onTap: () => Navigator.of(context).pop(n.id),
                    ),
                  );
                },
              ),
            ),
        ]),
      ),
    );
  }
}
