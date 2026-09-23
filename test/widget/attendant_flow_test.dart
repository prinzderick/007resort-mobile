import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/models/models.dart';
import 'package:r007_mobile/core/state/app_state.dart';
import 'package:r007_mobile/core/state/board.dart';

import '../helpers/harness.dart';

Future<Harness> signedInAttendant(WidgetTester tester) async {
  final h = Harness();
  await h.pump(tester);
  await enrolAs(tester, 'ATT-2026');
  await loginWith(tester, 'amaka', '1234');
  // checkout to the Restaurant
  await tester.tap(find.byKey(const Key('facility-f-restaurant')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('checkout-submit')));
  await settle(tester);
  return h;
}

void main() {
  testWidgets('bootstrap: enrol -> login -> tablet checkout -> tables', (
    tester,
  ) async {
    final h = await signedInAttendant(tester);
    final s = h.container.read(appControllerProvider);
    expect(s.device?.mode.apiValue, 'ATTENDANT');
    expect(s.checkout?.facility.id, 'f-restaurant');
    expect(find.byKey(const Key('table-tbl-f-restaurant-1')), findsOneWidget);
    expect(
      find.text('Select a table or customer\nto see and add orders'),
      findsOneWidget,
    );
  });

  testWidgets('wrong PIN shows a clear error and stays on login', (
    tester,
  ) async {
    final h = Harness();
    await h.pump(tester);
    await enrolAs(tester, 'ATT-2026');
    await loginWith(tester, 'amaka', '0000');
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
    expect(find.textContaining('Wrong username'), findsOneWidget);
  });

  testWidgets(
    'take order, send, see per-item status, get READY alert, mark served',
    (tester) async {
      final h = await signedInAttendant(tester);
      await tester.tap(find.byKey(const Key('table-tbl-f-restaurant-1')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('add-order')));
      await settle(tester);

      // browse: Starters is default; add suya twice, switch to Mains, add jollof
      await tester.tap(find.byKey(const Key('product-p-suya')));
      await tester.tap(find.byKey(const Key('product-p-suya')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('cat-c-mains')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('product-p-jollof')));
      await settle(tester);
      // jollof has an optional Extras group -> dialog
      await tester.tap(find.byKey(const Key('mod-add')));
      await settle(tester);

      // estimate is display only: 2 x 3500 + 6500 = 13500
      expect(find.byKey(const Key('cart-estimate')), findsOneWidget);
      expect(find.text('₦13,500.00'), findsOneWidget);

      await tester.tap(find.byKey(const Key('send-order')));
      await settle(tester);

      // back on the pane: order card with server number + SENT lines
      final board = h.container.read(boardProvider);
      expect(board.orders, hasLength(1));
      final order = board.orders.single;
      expect(order.status, OrderStatus.sent);
      expect(order.total, '13500.00'); // server truth
      expect(find.byKey(Key('order-${order.id}')), findsOneWidget);
      expect(find.text('ROUTED'), findsWidgets);

      // kitchen progresses; realtime is off in tests so refresh (as polling would)
      h.api.advance(order.id, LineStatus.inProgress);
      await h.container.read(boardProvider.notifier).refresh();
      await settle(tester);
      expect(find.text('IN PROGRESS'), findsWidgets);
      expect(h.container.read(boardProvider).alerts, isEmpty);

      h.api.advance(order.id, LineStatus.ready);
      await h.container.read(boardProvider.notifier).refresh();
      await settle(tester);
      // polling fallback raises the READY notification
      expect(h.container.read(boardProvider).alerts.single.kind, 'ready');
      expect(find.text('Order ready to serve'), findsOneWidget);

      await tester.tap(find.byKey(Key('serve-${order.id}')));
      await settle(tester);
      expect(
        h.container.read(boardProvider).orders.single.status,
        OrderStatus.served,
      );
    },
  );

  testWidgets('add a second order to the same open table/tab', (tester) async {
    final h = await signedInAttendant(tester);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const Key('table-tbl-f-restaurant-2')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('add-order')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('product-p-suya')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-order')));
      await settle(tester);
    }
    final orders = h.container.read(boardProvider).orders;
    expect(orders, hasLength(2));
    expect(orders.map((o) => o.tableId).toSet(), {'tbl-f-restaurant-2'});
  });

  testWidgets('new customer tab works for bars / no-table facilities', (
    tester,
  ) async {
    final h = Harness();
    await h.pump(tester);
    await enrolAs(tester, 'ATT-2026');
    await loginWith(tester, 'amaka', '1234');
    await tester.tap(find.byKey(const Key('facility-f-poolbar')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('checkout-submit')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('new-customer')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('customer-name')), 'Mr Bello');
    await tester.tap(find.byKey(const Key('customer-ok')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('product-b-star')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('send-order')));
    await settle(tester);
    final board = h.container.read(boardProvider);
    expect(board.tabs.single.customerName, 'Mr Bello');
    expect(board.orders.single.tabId, board.tabs.single.id);
    expect(find.text('Mr Bello'), findsWidgets);
  });

  testWidgets('idle lock requires the same staff PIN to resume', (
    tester,
  ) async {
    final h = await signedInAttendant(tester);
    h.container.read(appControllerProvider.notifier).lock();
    await settle(tester);
    expect(find.text('Tablet locked'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('lock-pin')), '9999');
    await tester.tap(find.byKey(const Key('lock-submit')));
    await settle(tester);
    // wrong PIN (or another staff's) keeps it locked
    expect(find.text('Tablet locked'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('lock-pin')), '1234');
    await tester.tap(find.byKey(const Key('lock-submit')));
    await settle(tester);
    expect(find.text('Tablet locked'), findsNothing);
    expect(find.byKey(const Key('table-tbl-f-restaurant-1')), findsOneWidget);
  });

  testWidgets('return tablet ends the shift and signs out', (tester) async {
    final h = await signedInAttendant(tester);
    await tester.tap(find.byKey(const Key('menu')));
    await settle(tester);
    await tester.tap(find.text('Return tablet (end of shift)'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('return-confirm')));
    await settle(tester);
    final s = h.container.read(appControllerProvider);
    expect(s.checkout, isNull);
    expect(s.session, isNull);
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
  });
}
