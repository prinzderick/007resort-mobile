/// Build-time configuration supplied via `--dart-define`.
///
/// | Define               | Default                   |
/// |----------------------|---------------------------|
/// | R007_API_BASE_URL  | http://10.0.2.2:5080      |
/// | R007_ENV           | dev                       |
///
/// `10.0.2.2` is the Android emulator alias for the host machine. Never put
/// secrets in dart-defines: they are embedded in the APK.
class AppConfig {
  const AppConfig({required this.apiBaseUrl, required this.environment});

  factory AppConfig.fromEnvironment() {
    return const AppConfig(
      apiBaseUrl: String.fromEnvironment(
        'R007_API_BASE_URL',
        defaultValue: defaultApiBaseUrl,
      ),
      environment: String.fromEnvironment(
        'R007_ENV',
        defaultValue: defaultEnvironment,
      ),
    );
  }

  static const String defaultApiBaseUrl = 'http://10.0.2.2:5080';
  static const String defaultEnvironment = 'dev';

  /// Base URL of the 007 Resort & Spa API (without the `/api/v1` prefix).
  final String apiBaseUrl;

  /// One of `dev`, `staging`, `production`.
  final String environment;

  bool get isProduction => environment == 'production';
}
