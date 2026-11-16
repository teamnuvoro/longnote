import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Things that leave the app (URLs, mail, share sheet, App Store review).
/// Tests replace the functions to record calls.
abstract final class External {
  static Future<bool> Function(Uri uri) openUrl = (uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  };

  static Future<void> Function(String text, {String? subject}) shareText =
      (text, {subject}) async {
    await SharePlus.instance.share(ShareParams(text: text, subject: subject));
  };

  /// Returns false when the review prompt is not available.
  static Future<bool> Function() requestReview = () async {
    try {
      final r = InAppReview.instance;
      if (!await r.isAvailable()) return false;
      await r.requestReview();
      return true;
    } catch (_) {
      return false;
    }
  };
}

/// Short message at the bottom of the screen.
void showNote(BuildContext context, String text) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
}

/// Opens [url]; if nothing can open it, says so (and copies [fallbackCopy]).
Future<bool> openOrExplain(BuildContext context, String url,
    {String? fallbackCopy, String? failText}) async {
  final ok = await External.openUrl(Uri.parse(url));
  if (ok || !context.mounted) return ok;
  if (fallbackCopy != null) {
    await Clipboard.setData(ClipboardData(text: fallbackCopy));
  }
  if (context.mounted) showNote(context, failText ?? 'Could not open the link.');
  return false;
}
