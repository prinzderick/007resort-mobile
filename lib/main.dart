import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';
import 'core/state/app_state.dart';
import 'core/storage/kv_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  final kv = SecureKvStore();
  final initial = await loadAppState(kv, config);
  runApp(
    ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        kvStoreProvider.overrideWithValue(kv),
        initialAppStateProvider.overrideWithValue(initial),
      ],
      child: const R007App(),
    ),
  );
}
