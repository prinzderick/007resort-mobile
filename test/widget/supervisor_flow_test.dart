import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/api/r007_api.dart';
import 'package:r007_mobile/core/models/models.dart';
import 'package:r007_mobile/core/state/approvals.dart';
import 'package:r007_mobile/core/state/board.dart';

import '../helpers/harness.dart';

/// Seeds the shared mock with one sent order made by a waiter.
Future<Harness> harnessWithWaiterOrder() async {
  final h = Harness();
  final api = h.api;
  final amaka = await api.loginStaff(
    identifier: 'amaka',
    secret: '1234',
    credentialType: 'PIN',
  );
  api.setSession(amaka);
  const draft = OrderDraft(
    id: 'ord-1',
    facilityId: 'f-restaurant',
    tableId: 'tbl-f-restaurant-1',
    tableName: 'T1',
    lines: [
      DraftLine(
        lineId: 'l1',
        productId: 'p-suya',
        name: 'Beef Suya',
        quantity: 2,
        estUnitPrice: '3500.00',
      ),
    ],
  );
  await api.createOrder(draft, idempotencyKey: 'k1');
  await api.sendOrder('ord-1', idempotencyKey: 'k2');
  api.setSession(null);
  return h;
}

void main() {
  testWidgets(
    'waiter void request -> supervisor sees it, approves with PIN, order voided',
    (tester) async {
      final h = await harnessWithWaiterOrder();
      final api = h.api;

      // Waiter holds order.void.execute but not .approve -> 202 approval
      final amaka = await api.loginStaff(
        identifier: 'amaka',
        secret: '1234',
        credentialType: 'PIN',
      );
      api.setSession(amaka);
      final r = await api.voidOrder(
        'ord-1',
        reason: 'Guest left',
        idempotencyKey: 'v1',
      );
      expect(r.isPending, isTrue);
      expect(r.order?.status, OrderStatus.pendingApproval);
      // replay with the same key returns the same outcome (idempotent)
      final again = await api.voidOrder(
        'ord-1',
        reason: 'Guest left',
        idempotencyKey: 'v1',
      );
      expect(again.approval?.id, r.approval?.id);
      api.setSession(null);

      // Supervisor tablet
      await h.pump(tester);
      await enrolAs(tester, 'SUP-2026');
      await loginWith(tester, 'ngozi', '9999');
      expect(find.byKey(const Key('tab-approvals')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tab-approvals')));
      await settle(tester);
      await h.container.read(approvalsProvider.notifier).refresh();
      await settle(tester);
      final pending = h.container.read(approvalsProvider).pending;
      expect(pending, hasLength(1));
      expect(find.byKey(Key('approval-${pending.single.id}')), findsOneWidget);
      expect(find.textContaining('Void order'), findsWidgets);

      // wrong PIN is rejected by the step-up
      await tester.tap(find.byKey(Key('approve-${pending.single.id}')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('decision-pin')), '0000');
      await tester.tap(find.byKey(const Key('decision-confirm')));
      await settle(tester);
      expect(h.container.read(approvalsProvider).pending, hasLength(1));

      await tester.tap(find.byKey(Key('approve-${pending.single.id}')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('decision-pin')), '9999');
      await tester.tap(find.byKey(const Key('decision-confirm')));
      await settle(tester);
      expect(h.container.read(approvalsProvider).pending, isEmpty);
      final order = await api.getOrder('ord-1');
      expect(order.status, OrderStatus.voided);
    },
  );

  testWidgets('supervisor rejects with a reason; order returns to its state', (
    tester,
  ) async {
    final h = await harnessWithWaiterOrder();
    final api = h.api;
    api.setSession(
      await api.loginStaff(
        identifier: 'amaka',
        secret: '1234',
        credentialType: 'PIN',
      ),
    );
    final res = await api.adjustLine(
      'ord-1',
      'l1',
      kind: 'DISCOUNT_PERCENT',
      value: '50',
      reason: 'Regular customer',
      idempotencyKey: 'd1',
    );
    expect(res.isPending, isTrue);
    api.setSession(null);

    await h.pump(tester);
    await enrolAs(tester, 'SUP-2026');
    await loginWith(tester, 'ngozi', '9999');
    await tester.tap(find.byKey(const Key('tab-approvals')));
    await settle(tester);
    await h.container.read(approvalsProvider.notifier).refresh();
    await settle(tester);
    final a = h.container.read(approvalsProvider).pending.single;
    await tester.tap(find.byKey(Key('reject-${a.id}')));
    await settle(tester);
    await tester.enterText(
      find.byKey(const Key('decision-note')),
      'Not authorised',
    );
    await tester.enterText(find.byKey(const Key('decision-pin')), '9999');
    await tester.tap(find.byKey(const Key('decision-confirm')));
    await settle(tester);
    final order = await api.getOrder('ord-1');
    expect(order.status, OrderStatus.sent);
    expect(order.total, '7000.00'); // discount NOT applied
  });

  testWidgets('supervisor live monitor shows facility orders with statuses', (
    tester,
  ) async {
    final h = await harnessWithWaiterOrder();
    h.api.advance('ord-1', LineStatus.ready);
    await h.pump(tester);
    await enrolAs(tester, 'SUP-2026');
    await loginWith(tester, 'ngozi', '9999');
    await h.container.read(boardProvider.notifier).refresh();
    await settle(tester);
    expect(find.byKey(const Key('order-ord-1')), findsOneWidget);
    expect(find.text('READY'), findsWidgets);
    // filter chips reflect status counts
    await tester.tap(find.byKey(const Key('filter-SERVED')));
    await settle(tester);
    expect(find.byKey(const Key('order-ord-1')), findsNothing);
  });

  testWidgets('supervisor can void directly (holds execute AND approve)', (
    tester,
  ) async {
    final h = await harnessWithWaiterOrder();
    await h.pump(tester);
    await enrolAs(tester, 'SUP-2026');
    await loginWith(tester, 'ngozi', '9999');
    await h.container.read(boardProvider.notifier).refresh();
    await settle(tester);
    await tester.tap(find.byKey(const Key('void-ord-1')));
    await settle(tester);
    await tester.enterText(
      find.byKey(const Key('reason-field')),
      'Wrong table',
    );
    await tester.tap(find.byKey(const Key('reason-confirm')));
    await settle(tester);
    expect((await h.api.getOrder('ord-1')).status, OrderStatus.voided);
  });
}
