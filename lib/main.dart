import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'core/api/api_client.dart';
import 'core/config/app_config.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  final apiClient = ApiClient(baseUrl: config.apiBaseUrl);
  runApp(R007App(config: config, apiClient: apiClient));
}
