import 'package:flutter/material.dart';

import '../core/api/api_client.dart';
import '../core/config/app_config.dart';
import 'router.dart';
import 'theme.dart';

/// Root widget of the 007 Resort & Spa tablet app.
///
/// There is ONE app build for all 18 tablets. The UI shown is driven by the
/// device mode that the API returns for this device's registration; it is
/// never hardcoded per build.
class R007App extends StatelessWidget {
  const R007App({super.key, required this.config, required this.apiClient});

  final AppConfig config;
  final ApiClient apiClient;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '007 Resort & Spa',
      debugShowCheckedModeBanner: !config.isProduction,
      theme: buildR007Theme(),
      onGenerateRoute: AppRouter.onGenerateRoute,
      initialRoute: AppRouter.home,
    );
  }
}
