/// Addresses the Settings and paywall screens open.
abstract final class AppLinks {
  static const supportEmail = 'support@novaralabs.in';

  // TODO(owner): real URLs once the site pages exist.
  static const privacyPolicy = 'https://novaralabs.in/longnote/privacy';
  static const terms = 'https://novaralabs.in/longnote/terms';

  // TODO(owner): App Store id after the app is created in App Store Connect.
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
