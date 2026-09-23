import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/api/r007_api.dart';
import 'package:r007_mobile/core/config/app_config.dart';
import 'package:r007_mobile/core/mock/mock_api.dart';
import 'package:r007_mobile/core/offline/offline_queue.dart';
import 'package:r007_mobile/core/state/app_state.dart';
import 'package:r007_mobile/core/state/connectivity.dart';
import 'package:r007_mobile/core/state/order_service.dart';
import 'package:r007_mobile/core/state/outbox.dart';
import 'package:r007_mobile/core/storage/kv_store.dart';

ProviderContainer container({
  required MockR007Api api,
  bool timers = false,
  AppState initial = const AppState(),
}) {
  final kv = MemoryKvStore();
  final c = ProviderContainer(
    overrides: [
      appConfigProvider.overrideWithValue(
        const AppConfig(useMock: true, presetApiBaseUrl: '', environment: 't'),
      ),
      kvStoreProvider.overrideWithValue(kv),
      initialAppStateProvider.overrideWithValue(initial),
      apiProvider.overrideWithValue(api),
      offlineQueueProvider.overrideWithValue(
        OfflineQueue(storage: MemoryQueueStorage(), crypto: QueueCrypto(kv)),
      ),
      timersEnabledProvider.overrideWithValue(timers),
      feedbackEnabledProvider.overrideWithValue(false),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<MockR007Api> signedInApi() async {
  final api = MockR007Api(latency: Duration.zero, autoProgress: false);
  api.setSession(
    await api.loginStaff(
      identifier: 'amaka',
      secret: '1234',
      credentialType: 'PIN',
    ),
  );
  return api;
}

/// Waits until any in-flight outbox replay has finished.
Future<void> settleOutbox(ProviderContainer c) async {
  for (var i = 0; i < 100 && c.read(outboxProvider).hasPending; i++) {
    await pumpEventQueue();
  }
}

const line = DraftLine(
  lineId: '0192f6a0-0000-7000-8000-0000000000a1',
  productId: 'p-suya',
  name: 'Beef Suya',
  quantity: 1,
  estUnitPrice: '3500.00',
);

void main() {
  test(
    'production wiring: connectivity controller builds with timers enabled (regression: state read in build)',
    () async {
      final c = container(api: await signedInApi(), timers: true);
      expect(c.read(connectivityProvider).online, isTrue);
      c.dispose(); // cancels the probe timer
    },
  );

  test(
    'probe: offline then online drains the outbox exactly once, in order',
    () async {
      final api = await signedInApi();
      final c = container(api: api);
      c.read(outboxProvider); // build
      api.setOffline(true);
      final svc = c.read(orderServiceProvider);
      final r = await svc.submit(
        const OrderDraft(
          id: '0192f6a0-0000-7000-8000-000000000001',
          facilityId: 'f-restaurant',
          tableId: 'tbl-f-restaurant-1',
          lines: [line],
        ),
        openTable: true,
      );
      expect(r.queued, isTrue);
      expect(c.read(connectivityProvider).online, isFalse);
      expect(c.read(outboxProvider).pending.map((o) => o.type), [
        'table.open',
        'order.create',
        'order.send',
      ]);

      // second order while still queued goes BEHIND the first (strict order)
      final r2 = await svc.submit(
        const OrderDraft(
          id: '0192f6a0-0000-7000-8000-000000000002',
          facilityId: 'f-restaurant',
          tableId: 'tbl-f-restaurant-1',
          lines: [line],
        ),
      );
      expect(r2.queued, isTrue);
      expect(c.read(outboxProvider).pending, hasLength(5));

      api.setOffline(false);
      await c.read(connectivityProvider.notifier).probe();
      await settleOutbox(c);
      expect(c.read(outboxProvider).pending, isEmpty);
      final orders = await api.listOrders('f-restaurant');
      expect(orders.map((o) => o.id).toSet(), {
        '0192f6a0-0000-7000-8000-000000000001',
        '0192f6a0-0000-7000-8000-000000000002',
      });
      expect(orders.every((o) => o.status == 'SENT'), isTrue);
    },
  );

  test(
    'a rejected queued order is surfaced as failed and does not block the next order',
    () async {
      final api = await signedInApi();
      final c = container(api: api);
      c.read(outboxProvider);
      api.setOffline(true);
      final svc = c.read(orderServiceProvider);
      await svc.submit(
        const OrderDraft(
          id: '0192f6a0-0000-7000-8000-000000000011',
          facilityId: 'f-restaurant',
          lines: [
            DraftLine(
              lineId: '0192f6a0-0000-7000-8000-0000000000b1',
              productId: 'p-sold-out', // becomes rejected by the server
              name: 'Lobster',
              quantity: 1,
              estUnitPrice: '25000.00',
            ),
          ],
        ),
      );
      await svc.submit(
        const OrderDraft(
          id: '0192f6a0-0000-7000-8000-000000000012',
          facilityId: 'f-restaurant',
          lines: [line],
        ),
      );
      api.setOffline(false);
      await c.read(outboxProvider.notifier).drain();
      await settleOutbox(c);
      final box = c.read(outboxProvider);
      expect(box.pending, isEmpty);
      expect(box.failed.map((o) => o.orderId).toSet(), {
        '0192f6a0-0000-7000-8000-000000000011',
      });
      expect(box.failed.first.error, contains('not available'));
      expect((await api.listOrders('f-restaurant')).map((o) => o.id), [
        '0192f6a0-0000-7000-8000-000000000012',
      ]);
    },
  );

  test(
    'idempotent replay: same key returns the same order, no duplicate',
    () async {
      final api = await signedInApi();
      const d = OrderDraft(
        id: '0192f6a0-0000-7000-8000-000000000021',
        facilityId: 'f-restaurant',
        lines: [line],
      );
      final a = await api.createOrder(d, idempotencyKey: 'k');
      final b = await api.createOrder(d, idempotencyKey: 'k');
      expect(b.id, a.id);
      expect((await api.listOrders('f-restaurant')), hasLength(1));
    },
  );

  test('client ids are UUIDv7', () {
    final id = newId();
    expect(id[14], '7'); // version nibble
    expect(RegExp(r'^[0-9a-f-]{36}$').hasMatch(id), isTrue);
  });

  test('sensitive actions are never queued: offline void throws', () async {
    final api = await signedInApi();
    final c = container(api: api);
    const d = OrderDraft(
      id: '0192f6a0-0000-7000-8000-000000000031',
      facilityId: 'f-restaurant',
      lines: [line],
    );
    await c.read(orderServiceProvider).submit(d);
    api.setOffline(true);
    await expectLater(
      c.read(orderServiceProvider).voidOrder(d.id, reason: 'x y z'),
      throwsA(isA<ApiOfflineException>()),
    );
    expect(c.read(outboxProvider).pending, isEmpty);
  });
}
