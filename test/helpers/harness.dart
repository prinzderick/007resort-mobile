import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/app/app.dart';
import 'package:r007_mobile/core/config/app_config.dart';
import 'package:r007_mobile/core/mock/mock_api.dart';
import 'package:r007_mobile/core/offline/offline_queue.dart';
import 'package:r007_mobile/core/state/app_state.dart';
import 'package:r007_mobile/core/state/outbox.dart';
import 'package:r007_mobile/core/storage/kv_store.dart';
import 'package:r007_mobile/features/sports/scanner_view.dart';

/// Wires the real app against the built-in Mock API with deterministic,
/// timer-free settings (no polling, no sound, no camera).
class Harness {
  Harness({MockR007Api? api, AppState? initial, MemoryKvStore? kv})
    : api = api ?? MockR007Api(latency: Duration.zero, autoProgress: false),
      kv = kv ?? MemoryKvStore(),
      initial = initial ?? const AppState() {
    queueStorage = MemoryQueueStorage();
    queue = OfflineQueue(storage: queueStorage, crypto: QueueCrypto(this.kv));
  }

  final MockR007Api api;
  final MemoryKvStore kv;
  final AppState initial;
  late final MemoryQueueStorage queueStorage;
  late final OfflineQueue queue;
  String? lastScannerCode;
  void Function(String)? scannerCallback;

  List<Override> get overrides => [
    appConfigProvider.overrideWithValue(
      const AppConfig(useMock: true, presetApiBaseUrl: '', environment: 'test'),
    ),
    kvStoreProvider.overrideWithValue(kv),
    initialAppStateProvider.overrideWithValue(initial),
    apiProvider.overrideWithValue(api),
    offlineQueueProvider.overrideWithValue(queue),
    timersEnabledProvider.overrideWithValue(false),
    feedbackEnabledProvider.overrideWithValue(false),
    scannerBuilderProvider.overrideWithValue((context, onCode) {
      scannerCallback = onCode;
      return const ColoredBox(color: Colors.black, key: Key('fake-scanner'));
    }),
  ];

  ProviderContainer? _container;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(overrides: overrides, child: const R007App()),
    );
    await tester.pumpAndSettle();
    _container = ProviderScope.containerOf(
      tester.element(find.byType(R007App)),
    );
    addTearDown(() async {
      // Dispose the tree so periodic timers/streams are cancelled.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  ProviderContainer get container => _container!;
}

/// Enrolled + signed-in states for shortcuts in widget tests.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

Future<void> enrolAs(
  WidgetTester tester,
  String code, {
  String kind = 'MOBILE_TABLET',
}) async {
  await tester.enterText(find.byKey(const Key('enrol-name')), 'Test Tablet');
  await tester.enterText(find.byKey(const Key('enrol-code')), code);
  await tester.tap(find.byKey(const Key('enrol-submit')));
  await settle(tester);
}

Future<void> loginWith(WidgetTester tester, String id, String pin) async {
  await tester.enterText(find.byKey(const Key('login-id')), id);
  await tester.enterText(find.byKey(const Key('login-secret')), pin);
  await tester.tap(find.byKey(const Key('login-submit')));
  await settle(tester);
}
