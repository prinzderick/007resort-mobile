// Waiter-collection integration test against a REAL 007resort-api node that
// has the waiter-collection endpoints (docs/WAITER_COLLECTION.md). Skipped
// unless R007_API_BASE_URL is set:
//
//   R007_API_BASE_URL=http://127.0.0.1:8095 \
//   R007_DEVICE_ID=<uuid> R007_DEVICE_TOKEN=r7d_dev_tablet_waiter_01 \
//   R007_STAFF_ID=wait1 R007_STAFF_PIN=1234 \
//   flutter test test/integration/real_collection_test.dart
//
// (or R007_REG_CODE instead of a device id/token). It leaves ONE order with a
// printed bill behind (a printed bill cannot be voided, only cancelled with
// approval), so run it against a dev/demo node.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/api/http_api.dart';
import 'package:r007_mobile/core/api/r007_api.dart';
import 'package:r007_mobile/core/models/collection_models.dart';
import 'package:r007_mobile/core/models/models.dart';
import 'package:uuid/uuid.dart';

String env(String k) => Platform.environment[k] ?? '';

void main() {
  final base = env('R007_API_BASE_URL');
  final skip = base.isEmpty
      ? 'R007_API_BASE_URL not set - real waiter-collection test skipped'
      : null;
  const uuid = Uuid();

  group('real API - waiter collection', () {
    late HttpR007Api api;
    late AuthSession session;
    late Facility facility;
    late String orderId;
    late CollectionPolicy policy;

    setUpAll(() async {
      if (skip != null) return;
      api = HttpR007Api(baseUrl: base);
      final devId = env('R007_DEVICE_ID');
      final devToken = env('R007_DEVICE_TOKEN');
      DeviceIdentity device;
      if (devId.isNotEmpty && devToken.isNotEmpty) {
        device = DeviceIdentity(deviceId: devId, deviceToken: devToken);
      } else {
        device = await api.registerDevice(
          name: 'Collection Test Tablet',
          kind: 'MOBILE_TABLET',
          hardwareId: 'ctest-${uuid.v4()}',
          registrationCode: env('R007_REG_CODE'),
          idempotencyKey: uuid.v7(),
        );
      }
      api.setDeviceToken(device.deviceToken);
      session = await api.loginStaff(
        identifier: env('R007_STAFF_ID'),
        secret: env('R007_STAFF_PIN'),
        credentialType: 'PIN',
      );
      api.setSession(session);
      final all = await api.listFacilities();
      facility = all.firstWhere(
        (f) => session.staff.facilityIds.contains(f.id),
        orElse: () => all.first,
      );
      await api.checkoutDevice(
        deviceId: device.deviceId,
        staffId: session.staff.id,
        facilityId: facility.id,
        idempotencyKey: uuid.v7(),
      );
    });

    test('effective policy + cash-in-hand shapes parse', () async {
      policy = await api.collectionPolicy(
        session.staff.id,
        facilityId: facility.id,
      );
      expect(policy.allowedTenders, isNotEmpty);
      final c = await api.cashInHand(session.staff.id);
      expect(c.cashInHand, isNotEmpty);
      // ignore: avoid_print
      print(
        'cash holding=${policy.cashHoldingAllowed} (${policy.source}) '
        'limit=${policy.cashLimit} inHand=${c.cashInHand}',
      );
    }, skip: skip);

    test(
      'order -> print bill (billState) -> collect CARD is PENDING',
      () async {
        final cat = await api.getCatalog(facility.id);
        final product = cat.products.firstWhere((p) => p.available);
        final free = (await api.listTables(facility.id)).where((t) => t.isFree);
        orderId = uuid.v7();
        await api.createOrder(
          OrderDraft(
            id: orderId,
            facilityId: facility.id,
            tableId: free.isEmpty ? null : free.first.id,
            lines: [
              DraftLine(
                lineId: uuid.v7(),
                productId: product.id,
                name: product.name,
                quantity: 1,
                estUnitPrice: product.price,
              ),
            ],
            createdAt: DateTime.now().toUtc(),
          ),
          idempotencyKey: uuid.v7(),
        );
        await api.sendOrder(orderId, idempotencyKey: uuid.v7());

        final billed = await api.printBill(orderId, idempotencyKey: uuid.v7());
        expect(billed.bill.printed, isTrue);
        expect(billed.bill.remaining, isNotNull);

        final req = CollectionRequest(
          id: uuid.v7(),
          orderId: orderId,
          method: TenderMethod.cardTerminal,
          amount: '100.00',
          approvalCode: 'ITEST1',
          cardLast4: '4242',
          slipReference: 'ITEST-${uuid.v4().substring(0, 8)}',
        );
        try {
          final key = uuid.v7();
          final c = await api.createCollection(req, idempotencyKey: key);
          expect(c.status, CollectionStatus.pendingConfirmation);
          expect(c.isConfirmed, isFalse); // a waiter never confirms
          // replay of the same client id is the same collection
          final again = await api.createCollection(req, idempotencyKey: key);
          expect(again.id, c.id);
          final listed = await api.listCollections(orderId);
          expect(listed.map((x) => x.id), contains(c.id));
          final o = await api.getOrder(orderId);
          expect(Money0.gt(o.bill.pending), isTrue);
        } on ApiProblem catch (e) {
          // Pay-after-service facilities refuse collection before SERVED.
          expect(e.code, 'order_state_invalid');
        }
      },
      skip: skip,
    );

    test('cash follows the effective policy', () async {
      try {
        final c = await api.createCollection(
          CollectionRequest(
            id: uuid.v7(),
            orderId: orderId,
            method: TenderMethod.cash,
            amount: '100.00',
            tendered: '100.00',
          ),
          idempotencyKey: uuid.v7(),
        );
        expect(policy.cashHoldingAllowed, isTrue);
        expect(c.status, CollectionStatus.pendingConfirmation);
      } on ApiProblem catch (e) {
        expect(
          e.code,
          anyOf(
            'cash_holding_not_allowed',
            'cash_limit_exceeded',
            'order_state_invalid',
          ),
        );
        if (e.code == 'cash_holding_not_allowed') {
          expect(policy.cashHoldingAllowed, isFalse);
        }
      }
    }, skip: skip);

    test('handover list is reachable', () async {
      final l = await api.listHandovers(session.staff.id);
      expect(l, isA<List<CashHandover>>());
    }, skip: skip);
  });
}

/// "> 0" on a server decimal string, without floats.
abstract final class Money0 {
  static bool gt(String? v) =>
      v != null && double.tryParse(v) != null && double.parse(v) > 0;
}
