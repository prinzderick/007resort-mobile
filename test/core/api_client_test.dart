import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:r007_mobile/core/api/api_client.dart';

void main() {
  group('ApiClient.getSystemInfo', () {
    test('calls GET /api/v1/system/info and parses the body', () async {
      late http.Request captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'name': '007 Resort & Spa API', 'version': '0.1.0'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = ApiClient(
        baseUrl: 'http://10.0.2.2:5080',
        httpClient: mock,
      );

      final info = await client.getSystemInfo();

      expect(captured.method, 'GET');
      expect(
        captured.url.toString(),
        'http://10.0.2.2:5080/api/v1/system/info',
      );
      expect(captured.headers['Accept'], 'application/json');
      expect(info.name, '007 Resort & Spa API');
      expect(info.version, '0.1.0');
    });

    test('preserves a base path and trailing slash', () async {
      late Uri url;
      final mock = MockClient((request) async {
        url = request.url;
        return http.Response('{}', 200);
      });
      final client = ApiClient(
        baseUrl: 'https://api.example.test/r007/',
        httpClient: mock,
      );

      await client.getSystemInfo();

      expect(
        url.toString(),
        'https://api.example.test/r007/api/v1/system/info',
      );
    });

    test('throws ApiException on non-2xx', () async {
      final mock = MockClient((_) async => http.Response('down', 503));
      final client = ApiClient(baseUrl: 'http://localhost', httpClient: mock);

      await expectLater(
        client.getSystemInfo(),
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'statusCode', 503),
        ),
      );
    });
  });
}
