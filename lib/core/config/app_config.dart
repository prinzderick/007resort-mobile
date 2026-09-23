/// Reverb/Pusher connection parameters (ASSUMED defaults; overridable).
///
/// Normally taken from `GET /system/info` -> `realtime`; the dart-defines are
/// only a fallback for servers that do not publish it.
class RealtimeConfig {
  const RealtimeConfig({
    this.host = '',
    this.appKey = const String.fromEnvironment(
      'R007_REVERB_KEY',
      defaultValue: 'r007-local',
    ),
    this.port = const int.fromEnvironment(
      'R007_REVERB_PORT',
      defaultValue: 8081,
    ),
    this.scheme = const String.fromEnvironment(
      'R007_REVERB_SCHEME',
      defaultValue: 'ws',
    ),
  });
  final String host;
  final String appKey;
  final int port;

  /// `ws` or `wss`.
  final String scheme;
}

/// Build-time configuration supplied via `--dart-define`.
///
/// | Define              | Default                | Meaning                          |
/// |---------------------|------------------------|----------------------------------|
/// | R007_MOCK           | false                  | Run against the built-in Mock API |
/// | R007_API_BASE_URL   | (empty)                | Preset server URL; else entered in-app |
/// | R007_ENV            | dev                    | dev / staging / production        |
/// | R007_IDLE_LOCK_SECS | 300                    | Auto-lock after inactivity        |
///
/// Never put secrets in dart-defines: they are embedded in the APK.
class AppConfig {
  const AppConfig({
    required this.useMock,
    required this.presetApiBaseUrl,
    required this.environment,
    this.idleLockSeconds = 300,
  });

  factory AppConfig.fromEnvironment() => const AppConfig(
    useMock: bool.fromEnvironment('R007_MOCK'),
    presetApiBaseUrl: String.fromEnvironment('R007_API_BASE_URL'),
    environment: String.fromEnvironment('R007_ENV', defaultValue: 'dev'),
    idleLockSeconds: int.fromEnvironment(
      'R007_IDLE_LOCK_SECS',
      defaultValue: 300,
    ),
  );

  final bool useMock;
  final String presetApiBaseUrl;
  final String environment;
  final int idleLockSeconds;

  bool get isProduction => environment == 'production';

  /// Reported to the server on device registration.
  static const appVersion = '0.1.0';
}
