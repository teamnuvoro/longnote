/// Third-party analytics destinations (Amplitude, Meta) behind one small
/// interface, so tests use fakes and never touch a network or a platform
/// channel. docs/ANALYTICS.md lists every event and where it goes.
///
/// Privacy rules (launch/privacy-policy.md section 6):
/// - never any note content: no audio, transcript, summary, Ask text, note
///   title, speaker name or file name in any event or property;
/// - Amplitude: no IP address, no IDFA, no IDFV (random device id);
/// - the "Share usage analytics" switch stops every sink.
library;

/// One remote destination. Implementations must never throw.
abstract class AnalyticsSink {
  /// [props] have already been passed through [remoteSafeProps].
  Future<void> track(String name, Map<String, Object> props);

  /// The Supabase anonymous user id (never a name or email).
  Future<void> setUserId(String? userId);

  /// The Settings switch ("Share usage analytics"). Off = nothing is sent.
  Future<void> setEnabled(bool enabled);
}

/// Property keys that must never leave the phone, whatever their value.
/// Matched case-insensitively against each key and each `_`-separated part
/// of it (so `note_title`, `fileName` and `transcript_text` are all caught).
const piiKeyDenylist = <String>{
  'title',
  'text',
  'transcript',
  'summary',
  'name',
  'filename',
  'file',
  'path',
  'question',
  'answer',
  'speaker',
  'speakers',
  'body',
  'content',
  'email',
  'phone',
  'subject',
  'message',
  'msg',
  'query',
  'prompt',
};

/// A string value is sent only when it looks like a code or an id
/// (`pdf`, `audio_interruption`, `timeout`, a uuid, an ISO date). Anything
/// that could be free text (an exception message, a file path) becomes
/// `other`.
final RegExp _safeToken = RegExp(r'^[A-Za-z0-9_.:+\-]{1,64}$');

bool isPiiKey(String key) {
  final k = key.toLowerCase();
  if (piiKeyDenylist.contains(k)) return true;
  final camelSplit = key
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
      .toLowerCase();
  return camelSplit.split(RegExp(r'[_\-.]')).any(piiKeyDenylist.contains);
}

/// The props a remote sink may see: denylisted keys dropped, nulls dropped,
/// only bool / num / short code-like strings kept.
Map<String, Object> remoteSafeProps(Map<String, Object?>? props) {
  final out = <String, Object>{};
  if (props == null) return out;
  for (final e in props.entries) {
    if (isPiiKey(e.key)) continue;
    final v = e.value;
    if (v == null) continue;
    if (v is bool || v is num) {
      out[e.key] = v;
    } else if (v is String) {
      out[e.key] = _safeToken.hasMatch(v) ? v : 'other';
    } else if (v is DateTime) {
      out[e.key] = v.toUtc().toIso8601String();
    }
    // Lists, maps and other objects are never forwarded.
  }
  return out;
}
