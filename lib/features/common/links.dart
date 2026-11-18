/// THE one place for every outside address the app shows or opens: privacy
/// policy, terms, support email, App Store id. Paywall (A1), Settings (G1),
/// Plan (G4) and the share text read from here; nothing else hard-codes them.
abstract final class AppLinks {
  // Live inbox (owner, 16 Nov 2026).
  static const supportEmail = 'support@novaralabs.in';

  // Live on novaralabs.in since 18 Nov 2026; the same URLs are set in App
  // Store Connect (privacy policy URL, support URL, description).
  static const privacyPolicy = 'https://novaralabs.in/longnote/privacy';
  static const terms = 'https://novaralabs.in/longnote/terms';
  static const support = 'https://novaralabs.in/longnote/support';
  static const website = 'https://novaralabs.in/longnote';

  // App Store Connect -> App Information -> Apple ID.
  static const appStoreId = '6835017154';
  static String get appStoreUrl => appStoreId.isEmpty
      ? website
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
