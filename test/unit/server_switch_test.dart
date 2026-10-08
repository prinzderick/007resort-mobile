import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/config/app_config.dart';
import 'package:r007_mobile/core/mock/mock_api.dart';
import 'package:r007_mobile/core/offline/offline_queue.dart';
import 'package:r007_mobile/core/state/app_state.dart';
import 'package:r007_mobile/core/state/outbox.dart';
import 'package:r007_mobile/core/storage/kv_store.dart';

const _local = 'http://192.168.1.10:8080';
const _online = 'https://api.example.test';

Future<(ProviderContainer, MemoryKvStore, OfflineQueue)> _setup({
  bool withDevice = true,
}) async {
  final kv = MemoryKvStore();
  kv.data[Keys.serverUrl] = _local;
  if (withDevice) {
    kv.data[Keys.device] = jsonEncode({
      'id': 'dev-local',
      'deviceToken': 'tok-local',
      'kind': 'MOBILE_TABLET',
      'name': 'Local tablet',
    });
  }
  const config = AppConfig(
    useMock: true,
    presetApiBaseUrl: '',
    environment: 't',
  );
  final queue = OfflineQueue(
    storage: MemoryQueueStorage(),
    crypto: QueueCrypto(kv),
  );
  final initial = await loadAppState(kv, config);
  final c = ProviderContainer(
    overrides: [
      appConfigProvider.overrideWithValue(config),
      kvStoreProvider.overrideWithValue(kv),
      initialAppStateProvider.overrideWithValue(initial),
      apiProvider.overrideWithValue(
        MockR007Api(latency: Duration.zero, autoProgress: false),
      ),
      offlineQueueProvider.overrideWithValue(queue),
      timersEnabledProvider.overrideWithValue(false),
      feedbackEnabledProvider.overrideWithValue(false),
    ],
  );
  addTearDown(c.dispose);
  return (c, kv, queue);
}

void main() {
  test(
    'switching keeps each server\'s enrolment and restores it on return',
    () async {
      final (c, kv, _) = await _setup();
      final ctrl = c.read(appControllerProvider.notifier);
      expect(c.read(appControllerProvider).device?.deviceId, 'dev-local');

      await ctrl.switchServer(_online);
      var s = c.read(appControllerProvider);
      expect(s.serverUrl, _online);
      expect(
        s.device,
        isNull,
        reason: 'the online server has no enrolment yet',
      );
      expect(c.read(serverUrlProvider), _online);
      expect(kv.data[Keys.serverUrl], _online);

      // Enrol "online" by hand, then go back: the local enrolment must be intact.
      kv.data[Keys.device] = jsonEncode({
        'id': 'dev-online',
        'deviceToken': 'tok-online',
        'kind': 'MOBILE_TABLET',
        'name': 'Online tablet',
      });
      await ctrl.switchServer(_local);
      s = c.read(appControllerProvider);
      expect(s.serverUrl, _local);
      expect(s.device?.deviceId, 'dev-local');
      expect(s.device?.deviceToken, 'tok-local');

      await ctrl.switchServer(_online);
      expect(c.read(appControllerProvider).device?.deviceId, 'dev-online');
      expect(await ctrl.knownServers(), [_online, _local]);
    },
  );

  test('switching to the current server is a no-op', () async {
    final (c, _, _) = await _setup();
    await c.read(appControllerProvider.notifier).switchServer(_local);
    expect(c.read(appControllerProvider).device?.deviceId, 'dev-local');
  });

  test('refuses to switch while offline records are waiting', () async {
    final (c, kv, queue) = await _setup();
    await queue.enqueueAll([
      QueuedOp(
        id: 'q1',
        type: 'cash_record',
        payload: const {},
        idempotencyKey: 'k1',
        createdAt: DateTime.now().toUtc(),
      ),
    ]);
    // The outbox mirrors the queue on build.
    c.read(outboxProvider);
    await expectLater(
      c.read(appControllerProvider.notifier).switchServer(_online),
      throwsA(isA<StateError>()),
    );
    expect(c.read(appControllerProvider).serverUrl, _local);
    expect(kv.data[Keys.serverUrl], _local);
  });
}
