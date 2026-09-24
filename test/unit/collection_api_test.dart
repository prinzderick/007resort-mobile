import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/models/collection_models.dart';
import 'package:r007_mobile/core/models/models.dart';

import 'http_api_test.dart' show FakeAdapter, apiWith, json, session;

Map<String, dynamic> payment({
  String status = 'PENDING_CONFIRMATION',
  String tender = 'CASH',
  Map<String, dynamic>? collection,
}) => {
  'id': 'p1',
  'status': status,
  'amount': '7000.0000',
  'tendered': '10000.0000',
  'changeGiven': '3000.0000',
  'createdAt': '2026-09-24T10:00:00Z',
  'allocations': [
    {'orderId': 'o1', 'amount': '7000.0000'},
  ],
  'collection': {'tender': tender, ...?collection},
};

void main() {
  test(
    'Order parses the additive bill fields (billState, collectable, ...)',
    () {
      final o = Order.fromJson({
        'id': 'o1',
        'status': 'SERVED',
        'total': '7000.0000',
        'billState': 'BILL_PRINTED',
        'awaitingPayment': true,
        'amountPaid': '1000.0000',
        'pendingCollected': '2000.0000',
        'collectable': '4000.0000',
      });
      expect(o.bill.printed, isTrue);
      expect(o.bill.confirmed, '1000.0000');
      expect(o.bill.pending, '2000.0000');
      expect(o.bill.remaining, '4000.0000');
      // an old server without the fields: bill is simply "not printed"
      expect(
        Order.fromJson({'id': 'x', 'status': 'SENT'}).bill.printed,
        isFalse,
      );
    },
  );

  test(
    'POST /orders/{id}/bill sends the idempotency key and parses {order}',
    () async {
      final a = FakeAdapter(
        (c) => json(200, {
          'order': {
            'id': 'o1',
            'status': 'SERVED',
            'billState': 'BILL_PRINTED',
          },
          'bill': {'kind': 'PRE_BILL'},
          'reprint': false,
        }),
      );
      final api = apiWith(a)..setSession(session);
      final o = await api.printBill('o1', idempotencyKey: 'k1');
      expect(o.bill.printed, isTrue);
      final c = a.calls.single;
      expect(c.method, 'POST');
      expect(c.path, endsWith('/api/v1/orders/o1/bill'));
      expect(c.headers['Idempotency-Key'], 'k1');
    },
  );

  test(
    'cash collection body: tenderType, client id, tendered; money as strings',
    () async {
      final a = FakeAdapter(
        (c) => json(201, {
          'payment': payment(),
          'order': {'id': 'o1'},
        }),
      );
      final api = apiWith(a)..setSession(session);
      final c = await api.createCollection(
        const CollectionRequest(
          id: '0190-id',
          orderId: 'o1',
          method: TenderMethod.cash,
          amount: '7000.00',
          tendered: '10000.00',
        ),
        idempotencyKey: 'k9',
      );
      expect(c.status, CollectionStatus.pendingConfirmation);
      expect(c.changeGiven, '3000.0000');
      expect(c.orderId, 'o1');
      final call = a.calls.single;
      expect(call.path, endsWith('/orders/o1/collections'));
      expect(call.headers['Idempotency-Key'], 'k9');
      final body = call.body! as Map;
      expect(body['id'], '0190-id');
      expect(body['tenderType'], 'CASH');
      expect(body['amount'], '7000.00');
      expect(body['tendered'], '10000.00');
      expect(body.containsKey('channel'), isFalse);
    },
  );

  test('card machine fields map to approvalCode / last4 / slipReference', () {
    const r = CollectionRequest(
      id: 'i',
      orderId: 'o1',
      method: TenderMethod.cardTerminal,
      amount: '500.00',
      approvalCode: 'AB12',
      cardLast4: '4242',
      slipReference: 'RRN1',
    );
    expect(r.toApi(), containsPair('last4', '4242'));
    expect(r.toApi(), containsPair('approvalCode', 'AB12'));
    expect(r.toApi(), containsPair('slipReference', 'RRN1'));
  });

  test(
    'transfer: no reference = PAYSTACK account (auto-confirm); reference = MANUAL',
    () {
      const auto = CollectionRequest(
        id: 'i',
        orderId: 'o1',
        method: TenderMethod.transfer,
        amount: '500.00',
      );
      const manual = CollectionRequest(
        id: 'i',
        orderId: 'o1',
        method: TenderMethod.transfer,
        amount: '500.00',
        bankReference: 'NIP1',
      );
      expect(auto.toApi()['channel'], 'PAYSTACK');
      expect(manual.toApi()['channel'], 'MANUAL');
    },
  );

  test(
    'pay link + transfer account come from the CollectionResult, AUTHORIZING = waiting',
    () async {
      final a = FakeAdapter(
        (c) => json(201, {
          'payment': payment(status: 'AUTHORIZING', tender: 'PAY_LINK'),
          'payLink': {
            'authorizationUrl': 'https://checkout.paystack.com/abc',
            'reference': 'R007-1',
          },
          'transferAccount': {
            'bankName': 'Wema',
            'accountNumber': '0123456789',
            'accountName': '007 RESORT',
          },
        }),
      );
      final api = apiWith(a)..setSession(session);
      final c = await api.createCollection(
        const CollectionRequest(
          id: 'i',
          orderId: 'o1',
          method: TenderMethod.payLink,
          amount: '7000.00',
        ),
        idempotencyKey: 'k',
      );
      expect(c.status, CollectionStatus.awaitingPayment);
      expect(c.isWaiting, isTrue);
      expect(c.qrData, 'https://checkout.paystack.com/abc');
      expect(c.transferAccountNumber, '0123456789');
    },
  );

  test(
    'payment status mapping: CAPTURED confirmed, REJECTED reason from the decision',
    () {
      final ok = Collection.fromPayment(payment(status: 'CAPTURED'));
      expect(ok.isConfirmed, isTrue);
      final rej = Collection.fromPayment(
        payment(
          status: 'REJECTED',
          collection: {'decisionReason': 'Slip does not match'},
        ),
      );
      expect(rej.isRejected, isTrue);
      expect(rej.rejectionReason, 'Slip does not match');
    },
  );

  test(
    'listCollections queries /payments by order and keeps collections only',
    () async {
      final a = FakeAdapter(
        (c) => json(200, {
          'items': [
            payment(),
            {
              'id': 'p2',
              'status': 'CAPTURED',
              'amount': '1.0000',
            }, // cashier payment
          ],
          'nextCursor': null,
        }),
      );
      final api = apiWith(a)..setSession(session);
      final l = await api.listCollections('o1');
      expect(l, hasLength(1));
      expect(a.calls.single.query['orderId'], 'o1');
    },
  );

  test('collection policy: effective cashHolding + allowed tenders', () async {
    final a = FakeAdapter(
      (c) => json(200, {
        'staffId': 's1',
        'collectionEnabled': true,
        'cashHolding': {'allowed': false, 'source': 'staff', 'limit': null},
        'allowedTenders': ['CARD_TERMINAL', 'TRANSFER'],
      }),
    );
    final api = apiWith(a)..setSession(session);
    final p = await api.collectionPolicy('s1', facilityId: 'f1');
    expect(p.cashHoldingAllowed, isFalse);
    expect(p.source, 'staff');
    expect(p.allows(TenderMethod.cash), isFalse);
    expect(p.allows(TenderMethod.cardTerminal), isTrue);
    expect(p.allows(TenderMethod.payLink), isFalse);
    expect(a.calls.single.query['facilityId'], 'f1');
  });

  test(
    'a node without the policy endpoint (404) keeps everything permissive',
    () async {
      final a = FakeAdapter(
        (c) => json(404, {'code': 'not_found', 'title': 'x'}),
      );
      final api = apiWith(a)..setSession(session);
      final p = await api.collectionPolicy('s1');
      expect(p.cashHoldingAllowed, isTrue);
    },
  );

  test(
    'cash-in-hand + handover: declared amount, PENDING_RECEIPT then variance',
    () async {
      final a = FakeAdapter(
        (c) => c.method == 'GET'
            ? json(200, {
                'cashInHand': '4500.0000',
                'limit': '5000.0000',
                'handoverRequired': false,
                'pendingCollections': 2,
                'pendingCollectionsAmount': '1000.0000',
              })
            : json(201, {
                'id': 'h1',
                'status': 'PENDING_RECEIPT',
                'expectedInHand': '4500.0000',
                'declaredAmount': '4500.0000',
                'countedAmount': null,
                'variance': null,
              }),
      );
      final api = apiWith(a)..setSession(session);
      final c = await api.cashInHand('s1');
      expect(c.cashInHand, '4500.0000');
      expect(c.pendingCollections, 2);
      final h = await api.createHandover(
        id: 'h1',
        declaredAmount: '4500.00',
        idempotencyKey: 'kh',
      );
      expect(h.isWaiting, isTrue);
      expect(h.variance, isNull);
      final post = a.calls.last;
      expect(post.path, endsWith('/cash-handovers'));
      expect((post.body! as Map)['declaredAmount'], '4500.00');
      expect(post.headers['Idempotency-Key'], 'kh');
    },
  );

  test(
    'CollectionRequest survives the offline-queue round trip (client id kept)',
    () {
      final r = CollectionRequest(
        id: '0190-id',
        orderId: 'o1',
        orderNumber: 'RST1-1',
        method: TenderMethod.cash,
        amount: '100.00',
        tendered: '200.00',
        collectedAt: DateTime.utc(2026, 9, 24, 10),
      );
      final back = CollectionRequest.fromJson(r.toJson());
      expect(back.id, '0190-id');
      expect(back.toApi(), r.toApi());
      expect(back.toPendingSync().status, CollectionStatus.pendingSync);
      expect(TenderMethod.queueable(TenderMethod.payLink), isFalse);
      expect(TenderMethod.needsNetwork(TenderMethod.transfer), isTrue);
    },
  );
}
