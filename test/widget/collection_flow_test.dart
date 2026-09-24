import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/api/r007_api.dart';
import 'package:r007_mobile/core/mock/mock_seed.dart';
import 'package:r007_mobile/core/models/collection_models.dart';
import 'package:r007_mobile/core/state/app_state.dart';
import 'package:r007_mobile/core/state/board.dart';
import 'package:r007_mobile/core/state/connectivity.dart';
import 'package:r007_mobile/core/state/outbox.dart';

import '../helpers/harness.dart';

const _table = 'tbl-f-restaurant-1';
final _amaka = mockStaff.first;

/// Signs in as [user], checks the tablet out to the Restaurant and places a
/// SENT order (2 x Beef Suya = 7,000.00) on T1 through the mock API.
Future<(Harness, String)> setup(
  WidgetTester tester, {
  String user = 'amaka',
  String pin = '1234',
  CollectionPolicy? policy,
}) async {
  final h = Harness();
  if (policy != null) h.api.policies[_amaka.id] = policy;
  await h.pump(tester);
  await enrolAs(tester, 'ATT-2026');
  await loginWith(tester, user, pin);
  await tester.tap(find.byKey(const Key('facility-f-restaurant')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('checkout-submit')));
  await settle(tester);
  final api = h.api;
  await api.openTable(_table, idempotencyKey: newId());
  final id = newId();
  await api.createOrder(
    OrderDraft(
      id: id,
      facilityId: 'f-restaurant',
      tableId: _table,
      tableName: 'T1',
      lines: [
        DraftLine(
          lineId: newId(),
          productId: 'p-suya',
          name: 'Beef Suya',
          quantity: 2,
          estUnitPrice: '3500.00',
        ),
      ],
    ),
    idempotencyKey: newId(),
  );
  await api.sendOrder(id, idempotencyKey: newId());
  await h.container.read(boardProvider.notifier).refresh();
  await settle(tester);
  await tester.tap(find.byKey(const Key('table-$_table')));
  await settle(tester);
  return (h, id);
}

/// Bounded pumps: the waiting view has an endless spinner.
Future<void> pumpN(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> printBill(WidgetTester tester, String orderId) async {
  await tester.tap(find.byKey(Key('print-bill-$orderId')));
  await settle(tester);
}

Future<void> openSheet(WidgetTester tester, String orderId) async {
  await tester.tap(find.byKey(Key('take-payment-$orderId')));
  await settle(tester);
}

Future<void> submit(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('submit-collection')));
  await tester.tap(find.byKey(const Key('submit-collection')));
  await pumpN(tester);
}

Future<void> fill(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

Future<List<Collection>> serverColls(Harness h, String orderId) =>
    h.api.listCollections(orderId);

void main() {
  testWidgets(
    'bill state: open -> print bill -> "Bill printed, awaiting payment"; '
    'order is locked (no void)',
    (tester) async {
      final (h, id) = await setup(tester);
      expect(find.text('Bill not printed yet'), findsOneWidget);
      expect(find.byKey(Key('take-payment-$id')), findsNothing);
      expect(find.byKey(Key('void-$id')), findsOneWidget);

      await printBill(tester, id);
      expect(find.text('Bill printed, awaiting payment'), findsOneWidget);
      // one alert (realtime + poll fallback share the id) that names the order
      expect(find.text('Bill printed - collect payment'), findsOneWidget);
      expect(find.textContaining('ORD-'), findsWidgets);
      expect(find.byKey(Key('take-payment-$id')), findsOneWidget);
      expect(find.byKey(Key('void-$id')), findsNothing); // frozen by the bill
      expect(
        h.container.read(boardProvider).orderById(id)!.bill.printed,
        isTrue,
      );
      // server totals are displayed, remaining = total
      expect(find.text('₦7,000.00'), findsWidgets);
    },
  );

  testWidgets('cash: pending until the cashier confirms; never paid by the '
      'waiter; then CONFIRMED and the order settles', (tester) async {
    final (h, id) = await setup(tester);
    await printBill(tester, id);
    await openSheet(tester, id);

    // amount pre-filled from the SERVER remaining
    final amount = tester.widget<TextField>(
      find.byKey(const Key('amount-field')),
    );
    expect(amount.controller!.text, '7000.00');
    await fill(tester, 'tendered-field', '10000');
    expect(find.text('Change to give: ₦3,000.00'), findsOneWidget);
    await submit(tester);

    var colls = await serverColls(h, id);
    expect(colls.single.status, CollectionStatus.pendingConfirmation);
    expect(colls.single.method, TenderMethod.cash);
    // still open: nothing settled by the waiter
    final o = h.container.read(boardProvider).orderById(id)!;
    expect(o.isOpen, isTrue);
    expect(o.bill.pending, '7000.00');
    expect(o.bill.confirmed, '0.00');
    expect(find.text('Pending cashier confirmation'), findsWidgets);
    expect(find.byKey(const Key('all-collected')), findsOneWidget);

    // cashier confirms -> realtime -> confirmed + order settled
    h.api.confirmCollection(colls.single.id);
    await settle(tester);
    colls = await serverColls(h, id);
    expect(colls.single.status, CollectionStatus.confirmed);
    expect(h.container.read(boardProvider).orderById(id), isNull);
    expect(find.text('Payment confirmed'), findsOneWidget);
  });

  testWidgets('split: cash + card machine; card needs an approval code; '
      'last 4 validated', (tester) async {
    final (h, id) = await setup(tester);
    await printBill(tester, id);
    await openSheet(tester, id);

    await fill(tester, 'amount-field', '2000');
    await fill(tester, 'tendered-field', '2000');
    await submit(tester);
    expect((await serverColls(h, id)), hasLength(1));

    await tester.tap(find.byKey(const Key('tender-CARD_TERMINAL')));
    await tester.pump();
    // remaining is refreshed from the server
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('amount-field')))
          .controller!
          .text,
      '5000.00',
    );
    await submit(tester); // missing approval code
    expect(find.textContaining('approval code'), findsWidgets);
    expect(await serverColls(h, id), hasLength(1));

    await fill(tester, 'approval-field', 'AB12');
    await fill(tester, 'last4-field', '12');
    await tester.enterText(find.byKey(const Key('last4-field')), '4242');
    await fill(tester, 'slip-field', 'RRN9001');
    await submit(tester);
    final colls = await serverColls(h, id);
    expect(colls, hasLength(2));
    final card = colls.firstWhere((c) => c.method == TenderMethod.cardTerminal);
    expect(card.approvalCode, 'AB12');
    expect(card.cardLast4, '4242');
    expect(card.slipReference, 'RRN9001');
    expect(find.byKey(const Key('all-collected')), findsOneWidget);
  });

  testWidgets('duplicate tap creates exactly one collection', (tester) async {
    final (h, id) = await setup(tester);
    await printBill(tester, id);
    await openSheet(tester, id);
    await fill(tester, 'tendered-field', '7000');
    final btn = find.byKey(const Key('submit-collection'));
    await tester.ensureVisible(btn);
    await tester.tap(btn);
    await tester.tap(btn, warnIfMissed: false);
    await tester.tap(btn, warnIfMissed: false);
    await settle(tester);
    expect(await serverColls(h, id), hasLength(1));
  });

  testWidgets(
    'cashier rejection shows the reason on the collection and an alert',
    (tester) async {
      final (h, id) = await setup(tester);
      await printBill(tester, id);
      await openSheet(tester, id);
      await tester.tap(find.byKey(const Key('tender-CARD_TERMINAL')));
      await tester.pump();
      await fill(tester, 'approval-field', '0000');
      await submit(tester);
      final c = (await serverColls(h, id)).single;
      h.api.rejectCollection(c.id, 'Slip does not match');
      await settle(tester);
      expect(find.byKey(Key('reject-reason-${c.id}')), findsWidgets);
      expect(find.text('Reason: Slip does not match'), findsWidgets);
      expect(find.text('Rejected'), findsWidgets);
      expect(find.text('Payment rejected by the cashier'), findsOneWidget);
      // the rejected money is collectable again
      final o = h.container.read(boardProvider).orderById(id)!;
      expect(o.bill.remaining, '7000.00');
    },
  );

  testWidgets(
    'pay link: QR + short link, waiting state flips to PAID via realtime',
    (tester) async {
      final (h, id) = await setup(tester);
      await printBill(tester, id);
      await openSheet(tester, id);
      await tester.tap(find.byKey(const Key('tender-PAY_LINK')));
      await tester.pump();
      await submit(tester);

      expect(find.byKey(const Key('waiting-view')), findsOneWidget);
      expect(find.byKey(const Key('pay-qr')), findsOneWidget);
      expect(find.byKey(const Key('short-link')), findsOneWidget);
      expect(find.byKey(const Key('waiting-label')), findsOneWidget);
      expect(find.text('Waiting for payment...'), findsOneWidget);

      final c = (await serverColls(h, id)).single;
      expect(c.status, CollectionStatus.awaitingPayment);
      h.api.confirmCollection(c.id); // provider confirms
      await settle(tester);
      expect(find.byKey(const Key('paid-banner')), findsOneWidget);
      expect(find.textContaining('PAID'), findsOneWidget);
    },
  );

  testWidgets('transfer: shows the bill account; with a bank reference it is a '
      'pending manual record', (tester) async {
    final (h, id) = await setup(tester);
    await printBill(tester, id);
    await openSheet(tester, id);
    await tester.tap(find.byKey(const Key('tender-TRANSFER')));
    await tester.pump();
    await fill(tester, 'amount-field', '3000');
    await submit(tester);
    expect(find.text('Account number'), findsOneWidget);
    expect(find.byKey(const Key('waiting-view')), findsOneWidget);
    await tester.tap(find.byKey(const Key('waiting-back')));
    await pumpN(tester);

    await tester.tap(find.byKey(const Key('tender-TRANSFER')));
    await tester.pump();
    await fill(tester, 'amount-field', '2000');
    await fill(tester, 'bankref-field', 'NIP123456');
    await submit(tester);
    final colls = await serverColls(h, id);
    final manual = colls.firstWhere((c) => c.bankReference == 'NIP123456');
    expect(manual.status, CollectionStatus.pendingConfirmation);
  });

  testWidgets('offline: cash/card records are queued as PENDING SYNC and sent '
      'on reconnect; pay link needs the network', (tester) async {
    final (h, id) = await setup(tester);
    await printBill(tester, id);
    await openSheet(tester, id);
    h.api.setOffline(true);

    // pay link cannot be created offline and is not queued
    await tester.tap(find.byKey(const Key('tender-PAY_LINK')));
    await tester.pump();
    await submit(tester);
    expect(find.textContaining('needs a connection'), findsWidgets);
    expect(h.container.read(outboxProvider).pending, isEmpty);

    // cash record is saved on the tablet
    await tester.tap(find.byKey(const Key('tender-CASH')));
    await tester.pump();
    await fill(tester, 'amount-field', '4000');
    await fill(tester, 'tendered-field', '5000');
    await submit(tester);
    final box = h.container.read(outboxProvider);
    expect(box.pending.map((o) => o.type).toList(), ['collection.record']);
    expect(find.text('Pending sync'), findsWidgets);
    // the ORDER itself is confirmed on the server: only the collection waits
    expect(find.text('PENDING CONFIRMATION'), findsNothing);
    // the amount already saved on the tablet is not offered again
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('amount-field')))
          .controller!
          .text,
      '3000.00',
    );
    expect(h.queueStorage.data, isNot(contains('collection.record')));

    // reconnect: replay is idempotent and lands as PENDING_CONFIRMATION
    h.api.setOffline(false);
    await h.container.read(connectivityProvider.notifier).probe();
    await settle(tester);
    expect(h.container.read(outboxProvider).pending, isEmpty);
    final colls = await serverColls(h, id);
    expect(colls, hasLength(1));
    expect(colls.single.amount, '4000.00');
    expect(colls.single.status, CollectionStatus.pendingConfirmation);
  });

  testWidgets('permissions: a trainee sees no Print bill / Take payment', (
    tester,
  ) async {
    final (_, id) = await setup(tester, user: 'chidi', pin: '2345');
    expect(find.byKey(Key('print-bill-$id')), findsNothing);
    expect(find.byKey(Key('take-payment-$id')), findsNothing);
    expect(find.textContaining('ask the cashier to print it'), findsOneWidget);
    expect(find.byKey(const Key('my-cash')), findsNothing);
  });

  testWidgets(
    'policy: cash NOT allowed -> Cash tender disabled with the reason, '
    'My cash hidden',
    (tester) async {
      final (h, id) = await setup(
        tester,
        policy: const CollectionPolicy(
          source: 'staff',
          cashHoldingAllowed: false,
        ),
      );
      expect(find.byKey(const Key('my-cash')), findsNothing);
      await printBill(tester, id);
      await openSheet(tester, id);
      expect(find.byKey(const Key('tender-reason-CASH')), findsOneWidget);
      expect(find.text('Cash goes to the cashier'), findsOneWidget);
      // defaults to the first usable tender (card machine)
      expect(find.byKey(const Key('approval-field')), findsOneWidget);
      // the server also refuses cash
      expect(
        () => h.api.createCollection(
          CollectionRequest(
            id: newId(),
            orderId: id,
            method: TenderMethod.cash,
            amount: '1000.00',
            tendered: '1000.00',
          ),
          idempotencyKey: newId(),
        ),
        throwsA(
          isA<ApiProblem>().having(
            (e) => e.code,
            'code',
            'cash_holding_not_allowed',
          ),
        ),
      );
    },
  );

  testWidgets(
    'policy: limit reached -> cash_limit_exceeded forces a handover prompt',
    (tester) async {
      final (h, id) = await setup(
        tester,
        policy: const CollectionPolicy(cashLimit: '5000.00'),
      );
      await printBill(tester, id);
      await openSheet(tester, id);
      await fill(tester, 'amount-field', '6000');
      await fill(tester, 'tendered-field', '6000');
      await submit(tester);
      expect(find.byKey(const Key('cash-limit-dialog')), findsOneWidget);
      expect(await serverColls(h, id), isEmpty);
      await tester.tap(find.byKey(const Key('cash-limit-handover')));
      await settle(tester);
      expect(find.text('My cash'), findsWidgets);
    },
  );

  testWidgets('My cash: cash in hand, limit warning, hand over -> waiting -> '
      'variance from the cashier count', (tester) async {
    final (h, id) = await setup(
      tester,
      policy: const CollectionPolicy(cashLimit: '5000.00'),
    );
    await printBill(tester, id);
    await openSheet(tester, id);
    await fill(tester, 'amount-field', '4500');
    await fill(tester, 'tendered-field', '4500');
    await submit(tester);
    await tester.tap(find.byKey(const Key('close-payment')));
    await settle(tester);

    await tester.tap(find.byKey(const Key('my-cash')));
    await settle(tester);
    expect(find.text('₦4,500.00'), findsWidgets);
    expect(find.byKey(const Key('limit-warning')), findsOneWidget); // >= 80%
    expect(find.byKey(const Key('today-summary')), findsOneWidget);

    // declaring more than held is refused by the server
    await fill(tester, 'declared-field', '9000');
    await tester.tap(find.byKey(const Key('handover-submit')));
    await settle(tester);
    expect(find.textContaining('more than the cash'), findsWidgets);

    await fill(tester, 'declared-field', '4500');
    await tester.tap(find.byKey(const Key('handover-submit')));
    await settle(tester);
    expect(
      find.textContaining('waiting for the cashier to count it'),
      findsOneWidget,
    );
    final ho = (await h.api.listHandovers(_amaka.id)).single;
    h.api.receiveHandover(ho.id, BigInt.from(445000)); // counted 4,450.00
    await settle(tester);
    await tester.tap(find.byKey(const Key('cash-refresh')));
    await settle(tester);
    expect(find.text('Received - you were SHORT'), findsOneWidget);
    expect(find.text('₦50.00'), findsOneWidget); // short by 50.00
  });
}
