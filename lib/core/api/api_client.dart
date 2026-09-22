import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thrown when the API returns a non-success status code.
class ApiException implements Exception {
  const ApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'ApiException($statusCode): $body';
}

/// Response of `GET /api/v1/system/info`.
class SystemInfo {
  const SystemInfo({required this.raw});

  factory SystemInfo.fromJson(Map<String, dynamic> json) =>
      SystemInfo(raw: Map.unmodifiable(json));

  /// Raw payload; the contract is owned by the API and will be typed once
  /// it is published in otueke-docs.
  final Map<String, dynamic> raw;

  String? get name => raw['name'] as String?;
  String? get version => raw['version'] as String?;
}

/// Minimal HTTP client for the Otueke API.
///
/// The API is the single source of truth for business rules. This client
/// only transports requests; it must never compute prices, validate tickets,
/// adjust inventory or decide permissions locally.
///
/// All mutating requests (POST/PUT/PATCH/DELETE) added later MUST send an
/// `Idempotency-Key` header containing a fresh UUID per logical operation.
class ApiClient {
  ApiClient({required String baseUrl, http.Client? httpClient})
    : _baseUri = Uri.parse(baseUrl),
      _http = httpClient ?? http.Client();

  static const String apiPrefix = '/api/v1';

  final Uri _baseUri;
  final http.Client _http;

  Uri _uri(String path) {
    final basePath = _baseUri.path.endsWith('/')
        ? _baseUri.path.substring(0, _baseUri.path.length - 1)
        : _baseUri.path;
    return _baseUri.replace(path: '$basePath$apiPrefix$path');
  }

  /// `GET /api/v1/system/info` - connectivity / version smoke check.
  Future<SystemInfo> getSystemInfo() async {
    final response = await _http.get(
      _uri('/system/info'),
      headers: const {'Accept': 'application/json'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, response.body);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object from /system/info');
    }
    return SystemInfo.fromJson(decoded);
  }

  void close() => _http.close();
}
