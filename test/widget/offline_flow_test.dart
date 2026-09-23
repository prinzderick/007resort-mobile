import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/models/models.dart';
import 'package:r007_mobile/core/offline/offline_queue.dart';
import 'package:r007_mobile/core/state/board.dart';
import 'package:r007_mobile/core/state/connectivity.dart';
import 'package:r007_mobile/core/state/outbox.dart';

import '../helpers/harness.dart';

void main() {
  testWidgets(
    'offline: order is queued as PENDING CONFIRMATION, then replayed in order when back online',
    (tester) async {
      final h = Harness();
      await h.pump(tester);
      await enrolAs(tester, 'ATT-2026');
      await loginWith(tester, 'amaka', '1234');
      await tester.tap(find.byKey(const Key('facility-f-restaurant')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('checkout-submit')));
      await settle(tester);

      // Menu is loaded (and cached) while online...
      await tester.tap(find.byKey(const Key('table-tbl-f-restaurant-3')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('add-order')));
      await settle(tester);
      // ...then Wi-Fi drops mid-order (mock switch in the demo strip)
      h.api.setOffline(true);
      await tester.tap(find.byKey(const Key('product-p-suya')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-order')));
      await settle(tester);

      // saved locally: open-table + create + send queued; UI says so
      final box = h.container.read(outboxProvider);
      expect(box.pending.map((o) => o.type).toList(), [
        'table.open',
        'order.create',
        'order.send',
      ]);
      expect(h.container.read(connectivityProvider).online, isFalse);
      expect(find.byKey(const Key('banner-offline')), findsOneWidget);
      expect(find.text('PENDING CONFIRMATION'), findsOneWidget);
      // nothing reached the server
      h.api.setOffline(false);
      expect(await h.api.listOrders('f-restaurant'), isEmpty);
      h.api.setOffline(true);

      // The queue on disk is encrypted: no plaintext ids/products
      expect(h.queueStorage.data, isNotNull);
      expect(h.queueStorage.data, isNot(contains('p-suya')));
      expect(h.queueStorage.data, isNot(contains('order.create')));

      // Reconnect: probe detects recovery and drains in order
      h.api.setOffline(false);
      await h.container.read(connectivityProvider.notifier).probe();
      await settle(tester);
      expect(h.container.read(outboxProvider).pending, isEmpty);
      expect(h.container.read(connectivityProvider).online, isTrue);
      await h.container.read(boardProvider.notifier).refresh();
      await settle(tester);
      final orders = h.container.read(boardProvider).orders;
      expect(orders, hasLength(1));
      expect(orders.single.status, OrderStatus.sent);
      expect(find.text('PENDING CONFIRMATION'), findsNothing);
      expect(find.byKey(const Key('banner-offline')), findsNothing);
    },
  );

  testWidgets(
    'offline with a full queue blocks new orders with a clear message',
    (tester) async {
      final h = Harness();
      await h.pump(tester);
      await enrolAs(tester, 'ATT-2026');
      await loginWith(tester, 'amaka', '1234');
      await tester.tap(find.byKey(const Key('facility-f-restaurant')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('checkout-submit')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('table-tbl-f-restaurant-4')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('add-order')));
      await settle(tester);
      h.api.setOffline(true);
      // fill the queue directly (bounded at 50)
      await h.queue.load();
      await h.queue.enqueueAll(List.generate(50, (i) => _op('x$i')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('product-p-suya')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-order')));
      await settle(tester);
      expect(find.textContaining('Reconnect to continue'), findsWidgets);
      expect(h.container.read(outboxProvider).pending, hasLength(50));
    },
  );
}

QueuedOp _op(String id) => QueuedOp(
  id: id,
  type: OpType.sendOrder,
  payload: {'orderId': id},
  idempotencyKey: 'k-$id',
  createdAt: DateTime.now().toUtc(),
  orderId: id,
);
