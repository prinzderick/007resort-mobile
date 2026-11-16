import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/models/models.dart';
import 'package:r007_mobile/core/models/waiter_flow.dart';

import 'http_api_test.dart' show FakeAdapter, apiWith, json, session;

void main() {
  test('rules: serviceFlow WAITER_ONLY switches the waiter-only flow on', () {
    expect(
      FacilityRules.fromJson({
        'operatingRules': {'serviceFlow': 'WAITER_ONLY'},
      }).waiterOnly,
      isTrue,
    );
    expect(
      FacilityRules.fromJson({
        'operatingRules': {'serviceFlow': 'STANDARD'},
      }).waiterOnly,
      isFalse,
    );
    expect(FacilityRules.fromJson({}).waiterOnly, isFalse);
  });

  test('open items parse groups, owners and totals', () {
    final items = OpenItems.fromJson({
      'scope': 'ALL',
      'groups': [
        {
          'key': 'k1',
          'tableLabel': 'T4',
          'customerName': 'Mr Ade',
          'ownerStaffId': 's1',
          'ownerName': 'Amaka',
          'balance': '9000.0000',
          'allServed': true,
          'handoverPending': false,
          'orders': [
            {
              'id': 'o1',
              'number': 'PB-1',
              'status': 'SERVED',
              'balance': '9000.0000',
              'canPay': true,
              'lines': [
                {'name': 'Chapman', 'quantity': 2},
              ],
            },
          ],
        },
      ],
      'waiters': [
        {
          'staffId': 's1',
          'name': 'Amaka',
          'tabs': 1,
          'orders': 1,
          'balance': '9000.0000',
        },
      ],
      'totals': {'balance': '9000.0000'},
    });
    expect(items.all, isTrue);
    expect(items.groups.single.label, 'T4 - Mr Ade');
    expect(items.groups.single.orderIds, ['o1']);
    expect(items.groups.single.orders.single.lines, ['2 x Chapman']);
    expect(items.waiters.single.name, 'Amaka');
  });

  test(
    'settle posts every order id and the tenders as strings, with the idempotency key',
    () async {
      final a = FakeAdapter(
        (c) => json(201, {
          'receiptId': 'r1',
          'changeDue': '500.0000',
          'closedTabIds': <String>['t1', 't2'],
          'orders': <String>[],
        }),
      );
      final api = apiWith(a)..setSession(session);
      final r = await api.waiterSettle(
        facilityId: 'f1',
        orderIds: ['o1', 'o2'],
        tenders: const [
          PayTender(type: 'CASH', amount: '8000', tendered: '8500'),
          PayTender(type: 'TRANSFER', amount: '3000', reference: 'TRF-1'),
        ],
        idempotencyKey: 'k9',
      );
      expect(r.receiptId, 'r1');
      expect(r.closedTabs, 2);
      final c = a.calls.single;
      expect(c.method, 'POST');
      expect(c.path, endsWith('/api/v1/waiter-flow/settle'));
      expect(c.headers['Idempotency-Key'], 'k9');
      final body = c.body as Map<String, dynamic>;
      expect(body['orderIds'], ['o1', 'o2']);
      expect((body['tenders'] as List).first, {
        'tenderType': 'CASH',
        'amount': '8000',
        'tendered': '8500',
      });
      expect(
        ((body['tenders'] as List<dynamic>).last
            as Map<String, dynamic>)['reference'],
        'TRF-1',
      );
    },
  );

  test(
    'hand-over: request, accept and the receipt print job use the right endpoints',
    () async {
      final handover = {
        'id': 'h1',
        'status': 'PENDING',
        'fromStaffId': 'a',
        'fromName': 'A',
        'toStaffId': 'b',
        'toName': 'B',
        'balance': '4500.0000',
        'items': [
          {'orderId': 'o1', 'number': 'PB-1', 'balance': '4500.0000'},
        ],
      };
      final a = FakeAdapter(
        (c) => json(c.path.endsWith('/print-jobs') ? 201 : 200, handover),
      );
      final api = apiWith(a)..setSession(session);
      final h = await api.requestTabHandover(
        facilityId: 'f1',
        toStaffId: 'b',
        note: 'end of shift',
        idempotencyKey: 'k1',
      );
      expect(h.pending, isTrue);
      expect(h.items.single.number, 'PB-1');
      await api.acceptTabHandover('h1', idempotencyKey: 'k2');
      await api.requestReceiptPrint('r1', copies: 2, idempotencyKey: 'k3');
      expect(a.calls.map((c) => c.path.split('/api/v1').last), [
        '/waiter-flow/handovers',
        '/waiter-flow/handovers/h1/accept',
        '/receipts/r1/print-jobs',
      ]);
      expect((a.calls.first.body as Map)['note'], 'end of shift');
      expect((a.calls.last.body as Map)['copies'], 2);
    },
  );
}
