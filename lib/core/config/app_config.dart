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
/// | R007_ONLINE_URL / R007_LOCAL_URL | (empty)   | Quick picks in the hidden Connection dialog |
/// | R007_CONNECTION_PIN | (empty)                | Optional PIN for that dialog      |
///
/// Never put secrets in dart-defines: they are embedded in the APK.
class AppConfig {
  const AppConfig({
    required this.useMock,
    required this.presetApiBaseUrl,
    required this.environment,
    this.idleLockSeconds = 300,
    this.connectionPin = '',
    this.onlineUrl = '',
    this.localUrl = '',
  });

  factory AppConfig.fromEnvironment() => const AppConfig(
    useMock: bool.fromEnvironment('R007_MOCK'),
    presetApiBaseUrl: String.fromEnvironment('R007_API_BASE_URL'),
    environment: String.fromEnvironment('R007_ENV', defaultValue: 'dev'),
    idleLockSeconds: int.fromEnvironment(
      'R007_IDLE_LOCK_SECS',
      defaultValue: 300,
    ),
    connectionPin: String.fromEnvironment('R007_CONNECTION_PIN'),
    onlineUrl: String.fromEnvironment('R007_ONLINE_URL'),
    localUrl: String.fromEnvironment('R007_LOCAL_URL'),
  );

  final bool useMock;
  final String presetApiBaseUrl;
  final String environment;
  final int idleLockSeconds;

  /// Optional PIN asked by the hidden Connection dialog (empty = none). Not a
  /// security boundary (it ships in the APK) - it only stops accidental switches.
  final String connectionPin;

  /// Quick-pick servers shown in the hidden Connection dialog.
  final String onlineUrl;
  final String localUrl;

  bool get isProduction => environment == 'production';

  /// Reported to the server on device registration.
  static const appVersion = '0.1.0';
}
