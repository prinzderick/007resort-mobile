// Integration test against a REAL 007resort-api node. Skipped unless
// R007_API_BASE_URL is provided (environment variable or --dart-define):
//
//   R007_API_BASE_URL=http://127.0.0.1:8080 \
//   R007_REG_CODE=ABC-123 R007_STAFF_ID=S-0042 R007_STAFF_PIN=4821 \
//   flutter test test/integration/real_api_test.dart
//
// Optional: R007_DEVICE_ID + R007_DEVICE_TOKEN (reuse an already registered
// device instead of a one-time R007_REG_CODE), R007_FACILITY_ID (checkout
// facility; default: first facility of the staff member / catalog tree),
// R007_QR_TOKEN (also exercises Sports Store lookup).
//
// It follows api/mvp-flows.md "Flow A" exactly and cleans up after itself
// (checks the tablet back in and logs out).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/api/http_api.dart';
import 'package:r007_mobile/core/api/r007_api.dart';
import 'package:r007_mobile/core/models/models.dart';
import 'package:uuid/uuid.dart';

String env(String key) {
  final v = Platform.environment[key] ?? '';
  if (v.isNotEmpty) return v;
  return switch (key) {
    'R007_API_BASE_URL' => const String.fromEnvironment('R007_API_BASE_URL'),
    'R007_REG_CODE' => const String.fromEnvironment('R007_REG_CODE'),
    'R007_STAFF_ID' => const String.fromEnvironment('R007_STAFF_ID'),
    'R007_STAFF_PIN' => const String.fromEnvironment('R007_STAFF_PIN'),
    _ => '',
  };
}

void main() {
  final base = env('R007_API_BASE_URL');
  final skip = base.isEmpty
      ? 'R007_API_BASE_URL not set - real-API integration test skipped'
      : null;
  const uuid = Uuid();

  group('real API (contract v1) - attendant slice', () {
    late HttpR007Api api;
    late DeviceIdentity device;
    late AuthSession session;
    Facility? facility;

    setUpAll(() async {
      api = HttpR007Api(baseUrl: base);
    });

    test('GET /system/info is public and reports realtime config', () async {
      final info = await api.systemInfo();
      expect(info.apiVersion, isNotEmpty);
      // ignore: avoid_print
      print(
        'node=${info.deploymentMode} realtime=${info.realtime?.host}:${info.realtime?.port}',
      );
    });

    test('register (or reuse) device, login with PIN', () async {
      final devId = env('R007_DEVICE_ID');
      final devToken = env('R007_DEVICE_TOKEN');
      if (devId.isNotEmpty && devToken.isNotEmpty) {
        device = DeviceIdentity(deviceId: devId, deviceToken: devToken);
      } else {
        device = await api.registerDevice(
          name: 'Integration Test Tablet',
          kind: 'MOBILE_TABLET',
          hardwareId: 'itest-${uuid.v4()}',
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
      expect(session.accessToken, isNotEmpty);
      expect(session.staff.permissions, isNotEmpty);
    });

    test('checkout tablet, load catalog + tables', () async {
      final all = await api.listFacilities();
      final wanted = env('R007_FACILITY_ID');
      final mine = session.staff.facilityIds;
      facility = all.firstWhere(
        (f) => wanted.isNotEmpty ? f.id == wanted : mine.contains(f.id),
        orElse: () => all.first,
      );
      final c = await api.checkoutDevice(
        deviceId: device.deviceId,
        staffId: session.staff.id,
        facilityId: facility!.id,
        idempotencyKey: uuid.v7(),
      );
      expect(c.facility.id, facility!.id);

      final cat = await api.getCatalog(facility!.id);
      expect(cat.products, isNotEmpty);
      final tables = await api.listTables(facility!.id);
      // ignore: avoid_print
      print('${cat.products.length} products, ${tables.length} tables');
    });

    test('create -> replay (idempotent) -> send -> list', () async {
      final cat = await api.getCatalog(facility!.id);
      final product = cat.products.firstWhere((p) => p.available);
      final tables = await api.listTables(facility!.id);
      final free = tables.where((t) => t.isFree).toList();
      final draft = OrderDraft(
        id: uuid.v7(),
        facilityId: facility!.id,
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
      );
      final key = uuid.v7();
      final created = await api.createOrder(draft, idempotencyKey: key);
      expect(created.id, draft.id); // client-supplied UUIDv7 honoured
      expect(created.status, OrderStatus.draft);
      expect(created.total, isNotNull); // server computed
      final replay = await api.createOrder(draft, idempotencyKey: key);
      expect(replay.id, created.id); // same result, no duplicate

      final sent = await api.sendOrder(created.id, idempotencyKey: uuid.v7());
      expect(sent.status, isNot(OrderStatus.draft));
      final open = await api.listOrders(facility!.id);
      expect(open.any((o) => o.id == created.id), isTrue);
    });

    test('approvals list is reachable for this staff member', () async {
      try {
        await api.listApprovals(scope: 'mine', status: 'PENDING');
      } on ApiProblem catch (e) {
        expect(e.status, anyOf(403, 404)); // permission-dependent
      }
    });

    test(
      'Sports Store lookup (only when R007_QR_TOKEN is given)',
      () async {
        final qr = Platform.environment['R007_QR_TOKEN'] ?? '';
        if (qr.isEmpty) return;
        final e = await api.getEntitlementByToken(qr);
        expect(e.items, isNotEmpty);
      },
      skip: (Platform.environment['R007_QR_TOKEN'] ?? '').isEmpty
          ? 'no R007_QR_TOKEN'
          : null,
    );

    tearDownAll(() async {
      try {
        await api.checkinDevice(
          deviceId: device.deviceId,
          idempotencyKey: uuid.v7(),
        );
        await api.logout();
      } on Object {
        // best effort cleanup
      }
    });
  }, skip: skip);
}
