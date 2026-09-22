import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otueke_mobile/app/app.dart';
import 'package:otueke_mobile/core/api/api_client.dart';
import 'package:otueke_mobile/core/config/app_config.dart';

void main() {
  testWidgets('app boots and shows the unregistered placeholder', (
    tester,
  ) async {
    final apiClient = ApiClient(
      baseUrl: AppConfig.defaultApiBaseUrl,
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );

    await tester.pumpWidget(
      OtuekeApp(config: AppConfig.fromEnvironment(), apiClient: apiClient),
    );

    expect(find.text('Device not registered'), findsOneWidget);
    expect(find.text('Mode: Unregistered'), findsOneWidget);
  });
}
