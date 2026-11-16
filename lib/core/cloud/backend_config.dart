/// Longnote backend: Supabase project "Longnote" (BACKEND-API.md).
///
/// ONLY the project URL and the anon (public) key may live in the app. The
/// anon key is public by design: alone it gets HTTP 401 from every function
/// (they require a signed-in user's token) and storage RLS limits each user
/// to their own folder. Every AI / transcription key is a server secret.
///
/// Override per build with
/// `--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...`.
class BackendConfig {
  const BackendConfig({required this.url, required this.anonKey});

  final String url;
  final String anonKey;

  static const _defaultUrl = 'https://twbqmfbaotdcxdpsylpn.supabase.co';
  static const _defaultAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR3YnFtZmJhb3RkY3hkcHN5bHBuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIxNDY0MDEsImV4cCI6MjEwNzcyMjQwMX0.0g-L7SakyaHU3aHtB17yRZ9EuJNEYcj_7KXvZX1_fgg';

  static const BackendConfig current = BackendConfig(
    url: String.fromEnvironment('SUPABASE_URL', defaultValue: _defaultUrl),
    anonKey:
        String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: _defaultAnonKey),
  );

  bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  /// `<ref>` = the subdomain of the URL.
  String get projectRef => Uri.parse(url).host.split('.').first;

  Uri get authSignUp => Uri.parse('$url/auth/v1/signup');
  Uri get authRefresh =>
      Uri.parse('$url/auth/v1/token?grant_type=refresh_token');
  Uri function(String name) => Uri.parse('$url/functions/v1/$name');

  /// Direct storage host: faster for big uploads (BACKEND-API 2).
  Uri get tusEndpoint => Uri.parse(
      'https://$projectRef.storage.supabase.co/storage/v1/upload/resumable');

  static const bucket = 'uploads';
}
