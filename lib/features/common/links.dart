/// THE one place for every outside address the app shows or opens: privacy
/// policy, terms, support email, App Store id. Paywall (A1), Settings (G1),
/// Plan (G4) and the share text read from here; nothing else hard-codes them.
abstract final class AppLinks {
  // TODO(owner): confirm the support inbox exists and is read.
  static const supportEmail = 'support@novaralabs.in';

  // TODO(owner): publish these pages (App Store review needs a live privacy
  // policy URL), then replace the placeholders if the paths differ.
  static const privacyPolicy = 'https://novaralabs.in/longnote/privacy';
  static const terms = 'https://novaralabs.in/longnote/terms';

  // TODO(owner): the numeric Apple ID from App Store Connect (App
  // Information -> Apple ID), e.g. '6501234567'. Until set, "Rate" and
  // "Share with a friend" use the website below.
  static const appStoreId = '';
  static String get appStoreUrl => appStoreId.isEmpty
      ? 'https://novaralabs.in/longnote'
      : 'https://apps.apple.com/app/id$appStoreId';

  /// Apple's own subscriptions page (cancel / change plan).
  static const manageSubscriptions =
      'itms-apps://apps.apple.com/account/subscriptions';
  static const manageSubscriptionsWeb =
      'https://apps.apple.com/account/subscriptions';

  static String mail({required String subject, String body = ''}) =>
      Uri(scheme: 'mailto', path: supportEmail, query: _query({
        'subject': subject,
        if (body.isNotEmpty) 'body': body,
      })).toString();

  // Uri(queryParameters:) encodes spaces as '+', which Mail shows literally.
  static String _query(Map<String, String> m) => m.entries
      .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
      .join('&');
}
