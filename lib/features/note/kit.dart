import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/notes/languages.dart';
import '../../ui/widgets.dart';

/// Small helpers shared by the Notes (B), Recording (C) and Note (D) screens.
/// Kept inside the feature folders so the design system stays untouched.

/// Icons added for B/C/D (Figma exports in assets/icons/, Lucide style).
enum NoteIcons {
  shareFile('share_file'),
  shareList('share_list'),
  shareQuote('share_quote'),
  shareAudio('share_audio'),
  styleUsers('style_users'),
  styleBook('style_book'),
  styleChat('style_chat'),
  styleMic('style_mic'),
  styleHandshake('style_handshake'),
  styleBulb('style_bulb'),
  styleChurch('style_church'),
  styleHeart('style_heart'),
  styleTodo('style_todo'),
  stylePlus('style_plus'),
  back15('player_back15'),
  fwd15('player_fwd15'),
  bell('processing_bell');

  const NoteIcons(this.file);
  final String file;
  String get asset => 'assets/icons/$file.svg';
}

class NoteIcon extends StatelessWidget {
  const NoteIcon(this.icon, {super.key, this.size = 18, this.color = LnColors.ink});
  final NoteIcons icon;
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => SvgPicture.asset(icon.asset,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn));
}

/// Quiet rounded square holding an icon (share rows, style rows, moments).
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.child,
    this.size = 34,
    this.radius = 10,
    this.color = LnColors.fill,
  });
  final Widget child;
  final double size;
  final double radius;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(radius)),
        child: child,
      );
}

// ---- formatting ---------------------------------------------------------------

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _weekdaysLong = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
];

/// "1:12:40", "48:10", "0:05" (Figma note rows, transcript times).
String clockText(int ms) {
  final d = Duration(milliseconds: ms < 0 ? 0 : ms);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// Recording timer: always "00:42:17".
String timerText(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
}

/// "10:24 AM".
String timeOfDay(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

int _daysAgo(DateTime d, DateTime now) => DateTime(now.year, now.month, now.day)
    .difference(DateTime(d.year, d.month, d.day))
    .inDays;

/// Day group label on Notes: Today / Yesterday / Monday / Nov 3 / Nov 3, 2025.
String dayGroupLabel(DateTime d, DateTime now) {
  final ago = _daysAgo(d, now);
  if (ago == 0) return 'Today';
  if (ago == 1) return 'Yesterday';
  if (ago > 1 && ago < 7) return _weekdaysLong[d.weekday - 1];
  return '${_months[d.month - 1]} ${d.day}${d.year == now.year ? '' : ', ${d.year}'}';
}

/// "Today, 10:24 AM" / "Yesterday, 2:00 PM" / "Nov 3, 10:24 AM".
String dayAndTime(DateTime d, DateTime now) {
  final ago = _daysAgo(d, now);
  final day = ago == 0
      ? 'Today'
      : ago == 1
          ? 'Yesterday'
          : '${_months[d.month - 1]} ${d.day}${d.year == now.year ? '' : ', ${d.year}'}';
  return '$day, ${timeOfDay(d)}';
}

/// "Sun, Nov 16" (recording screen).
String shortDate(DateTime d) =>
    '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}';

/// "English", or "Auto-detect" for auto.
String languageName(String? code) {
  if (code == null || code == 'auto') return 'Auto-detect';
  return audioLanguageFor(code).name;
}

/// "1 h 48 min", "42 minutes".
String spokenLength(Duration d) {
  final mins = d.inMinutes;
  if (mins < 1) return '${d.inSeconds} seconds';
  if (mins < 60) return mins == 1 ? '1 minute' : '$mins minutes';
  final h = mins ~/ 60;
  final m = mins % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

// ---- feedback ---------------------------------------------------------------------

/// Short ink toast at the bottom (copy done, moment marked ...).
void showToast(BuildContext context, String message) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    backgroundColor: LnColors.ink,
    elevation: 0,
    margin: const EdgeInsets.fromLTRB(20, 0, 20, 96),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    duration: const Duration(seconds: 2),
    content: Text(message, style: LnText.rowLabel.copyWith(color: LnColors.card)),
  ));
}

/// Light confirm dialog in the C4 shape (icon, serif title, body, two
/// full-width buttons). Returns true when the destructive action is chosen.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool dark = false,
}) async {
  final ok = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: cancelLabel,
    barrierColor: dark ? const Color(0x99000000) : LnColors.scrim,
    transitionDuration: const Duration(milliseconds: 220),
    transitionBuilder: (c, a, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
      child: ScaleTransition(
        scale: Tween(begin: 0.96, end: 1.0)
            .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
    pageBuilder: (c, _, _) => ConfirmCard(
      title: title,
      body: body,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      dark: dark,
      onConfirm: () => Navigator.of(c).pop(true),
      onCancel: () => Navigator.of(c).pop(false),
    ),
  );
  return ok == true;
}

/// The dialog card itself (Figma C4 6:686), also used light for "Delete note".
class ConfirmCard extends StatelessWidget {
  const ConfirmCard({
    super.key,
    required this.title,
    required this.body,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.onConfirm,
    required this.onCancel,
    this.dark = false,
  });
  final String title;
  final String body;
  final String confirmLabel;
  final String cancelLabel;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final bg = dark ? LnColors.nightRaised : LnColors.card;
    final border = dark ? LnColors.nightFill : LnColors.line;
    final fg = dark ? LnColors.nightText : LnColors.ink;
    final fg2 = dark ? LnColors.nightText2 : LnColors.ink2;
    Widget button(String label, Color bg, Color fg, VoidCallback onTap) =>
        LnPressable(
          onPressed: onTap,
          semanticLabel: label,
          child: Container(
            height: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: bg, borderRadius: BorderRadius.circular(LnRadius.button)),
            child: Text(label,
                style: LnText.headline.copyWith(fontSize: 16, color: fg)),
          ),
        );
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: dark
                          ? LnColors.recordingPillBg
                          : LnColors.destructiveTint,
                      shape: BoxShape.circle),
                  child: LnIcon(LnIcons.trash,
                      size: 20,
                      color: dark
                          ? LnColors.recordingPillText
                          : LnColors.destructiveText),
                ),
                const SizedBox(height: 14),
                Text(title, style: LnText.noteTitle.copyWith(color: fg)),
                const SizedBox(height: 6),
                Text(body,
                    style: LnText.body.copyWith(
                        fontSize: 15, height: 22 / 15, color: fg2)),
                const SizedBox(height: 20),
                button(confirmLabel, LnColors.signal, LnColors.card, onConfirm),
                const SizedBox(height: 8),
                button(cancelLabel, dark ? LnColors.nightFill : LnColors.fill,
                    fg, onCancel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Text-entry sheet (rename a note / the recording title).
Future<String?> askForText(
  BuildContext context, {
  required String title,
  required String initial,
  String action = 'Save',
  String? hint,
}) {
  return showLnSheet<String>(
    context,
    builder: (c) => _TextSheet(title: title, initial: initial, action: action, hint: hint),
  );
}

class _TextSheet extends StatefulWidget {
  const _TextSheet(
      {required this.title, required this.initial, required this.action, this.hint});
  final String title;
  final String initial;
  final String action;
  final String? hint;
  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final _ctl = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _save() {
    final v = _ctl.text.trim();
    Navigator.of(context).pop(v.isEmpty ? null : v);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: LnSheet(
        title: widget.title,
        leadingAction: LnSheetAction('Cancel',
            onPressed: () => Navigator.of(context).pop()),
        trailingAction:
            LnSheetAction(widget.action, emphasized: true, onPressed: _save),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CupertinoTheme(
            data: const CupertinoThemeData(primaryColor: LnColors.ink),
            child: LnTextField(controller: _ctl, autofocus: true, hint: widget.hint),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

/// Bold+underlined spans for text with [NoteSearch.markStart]/[markEnd]
/// markers (B3 hits, transcript search).
List<TextSpan> markedSpans(String text, TextStyle base, TextStyle hit,
    {String start = '\u0002', String end = '\u0003'}) {
  final out = <TextSpan>[];
  var i = 0;
  while (i < text.length) {
    final s = text.indexOf(start, i);
    if (s < 0) {
      out.add(TextSpan(text: text.substring(i), style: base));
      break;
    }
    if (s > i) out.add(TextSpan(text: text.substring(i, s), style: base));
    final e = text.indexOf(end, s + 1);
    final stop = e < 0 ? text.length : e;
    out.add(TextSpan(text: text.substring(s + 1, stop), style: hit));
    i = e < 0 ? text.length : e + 1;
  }
  return out;
}

/// Wraps case-insensitive matches of [query] words in markers.
String markMatches(String text, String query) {
  final words = query
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map(RegExp.escape)
      .toList();
  if (words.isEmpty) return text;
  final re = RegExp(words.join('|'), caseSensitive: false);
  return text.replaceAllMapped(re, (m) => '\u0002${m[0]}\u0003');
}
