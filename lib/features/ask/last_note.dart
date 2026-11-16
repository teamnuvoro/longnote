import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/models/recording.dart';

/// kv key: the note the user opened last (note screen or Ask picker). Ask
/// preselects it.
const kvLastOpenedNote = 'last_opened_note';

/// Called when a note screen opens (router) and when a note is picked in Ask.
/// Silently does nothing without an [AppServices] above [context].
void rememberOpenedNote(BuildContext context, String id) {
  AppServices? s;
  try {
    s = Provider.of<AppServices>(context, listen: false);
  } catch (_) {
    return;
  }
  s.kv.set(kvLastOpenedNote, id);
}

/// A note Ask can answer about: it has a transcript.
bool askable(Recording n) => n.processingStatus == ProcessingStatus.done;

/// Which note Ask starts with: [requested] if given, else the last opened
/// note, else the newest note with a transcript.
Future<Recording?> pickAskNote(AppServices s, {String? requested}) async {
  if (requested != null) {
    final r = await s.repo.get(requested);
    if (r != null) return r;
  }
  final last = await s.kv.get(kvLastOpenedNote);
  if (last != null) {
    final r = await s.repo.get(last);
    if (r != null && askable(r)) return r;
  }
  for (final n in await s.repo.all()) {
    if (askable(n)) return n;
  }
  return null;
}
