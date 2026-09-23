import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/api/http_api.dart';
import 'package:r007_mobile/core/api/r007_api.dart';
import 'package:r007_mobile/core/models/models.dart';

class Call {
  Call(this.method, this.path, this.headers, this.body, this.query);
  final String method;
  final String path;
  final Map<String, dynamic> headers;
  final Object? body;
  final Map<String, dynamic> query;
}

typedef Responder = ResponseBody Function(Call call);

ResponseBody json(int status, Object body, {Map<String, List<String>>? h}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [
          status >= 400 ? 'application/problem+json' : 'application/json',
        ],
        ...?h,
      },
    );

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.responder);
  final Responder responder;
  final calls = <Call>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final c = Call(
      options.method,
      options.uri.toString(),
      options.headers,
      options.data,
      options.queryParameters,
    );
    calls.add(c);
    return responder(c);
  }

  @override
  void close({bool force = false}) {}
}

HttpR007Api apiWith(FakeAdapter a) {
  final dio = Dio(BaseOptions(validateStatus: (_) => true))
    ..httpClientAdapter = a;
  return HttpR007Api(baseUrl: 'http://10.0.0.5:8080/', dio: dio);
}

final session = AuthSession(
  accessToken: 'tok',
  refreshToken: 'ref',
  expiresAt: DateTime.utc(2030),
  staff: const Staff(id: 's1', name: 'Amaka'),
);

Map<String, dynamic> orderJson({int rv = 1, String status = 'DRAFT'}) => {
  'id': 'o1',
  'number': 'RST1-1',
  'facilityId': 'f1',
  'status': status,
  'lines': [
    {
      'id': 'l1',
      'productId': 'p1',
      'name': 'Suya',
      'quantity': 2,
      'unitPrice': '3500.0000',
      'lineTotal': '7000.0000',
      'status': 'PENDING',
    },
  ],
  'subtotal': '7000.0000',
  'taxTotal': '0.0000',
  'total': '7000.0000',
  'amountPaid': '0.0000',
  'balanceDue': '7000.0000',
  'currency': 'NGN',
  'rowVersion': rv,
};

void main() {
  test(
    'base URL gets /api/v1; device + bearer + idempotency headers are sent',
    () async {
      final a = FakeAdapter(
        (c) => json(
          201,
          orderJson(),
          h: {
            'etag': ['"v1"'],
          },
        ),
      );
      final api = apiWith(a)
        ..setDeviceToken('dev-token')
        ..setSession(session);
      const draft = OrderDraft(
        id: '0192f6a0-0000-7000-8000-000000000001',
        facilityId: 'f1',
        tableId: 't1',
        lines: [
          DraftLine(
            lineId: '0192f6a0-0000-7000-8000-000000000002',
            productId: 'p1',
            name: 'Suya',
            quantity: 2,
            estUnitPrice: '3500.00',
            note: 'no pepper',
          ),
        ],
      );
      final o = await api.createOrder(draft, idempotencyKey: 'idem-1');
      expect(o.total, '7000.0000');
      final c = a.calls.single;
      expect(c.method, 'POST');
      expect(c.path, 'http://10.0.0.5:8080/api/v1/orders');
      expect(c.headers['Idempotency-Key'], 'idem-1');
      expect(c.headers['X-Device-Token'], 'dev-token');
      expect(c.headers['Authorization'], 'Bearer tok');
      expect(c.headers['X-Correlation-Id'], isNotEmpty);
      final body = c.body! as Map<String, dynamic>;
      expect(body['id'], draft.id);
      expect(body['facilityId'], 'f1');
      expect(body['tableId'], 't1');
      final line = (body['lines'] as List).single as Map<String, dynamic>;
      // the client NEVER sends prices
      expect(line.keys, containsAll(['id', 'productId', 'quantity', 'notes']));
      expect(line.containsKey('unitPrice'), isFalse);
      expect(line.containsKey('estUnitPrice'), isFalse);
      expect(line['notes'], 'no pepper');
    },
  );

  test('send uses If-Match from the create ETag (no extra GET)', () async {
    final a = FakeAdapter((c) {
      if (c.method == 'POST' && c.path.endsWith('/orders')) {
        return json(
          201,
          orderJson(),
          h: {
            'etag': ['"v1"'],
          },
        );
      }
      return json(
        200,
        orderJson(rv: 2, status: 'SENT'),
        h: {
          'etag': ['"v2"'],
        },
      );
    });
    final api = apiWith(a)..setSession(session);
    await api.createOrder(
      const OrderDraft(id: 'o1', facilityId: 'f1', lines: []),
      idempotencyKey: 'k1',
    );
    final sent = await api.sendOrder('o1', idempotencyKey: 'k2');
    expect(sent.status, 'SENT');
    expect(a.calls, hasLength(2));
    expect(a.calls.last.headers['If-Match'], '"v1"');
    expect(a.calls.last.headers['Idempotency-Key'], 'k2');
  });

  test('a queued send with no cached ETag fetches it first', () async {
    final a = FakeAdapter((c) {
      if (c.method == 'GET') {
        return json(
          200,
          orderJson(rv: 4),
          h: {
            'etag': ['"v4"'],
          },
        );
      }
      return json(
        200,
        orderJson(rv: 5, status: 'SENT'),
        h: {
          'etag': ['"v5"'],
        },
      );
    });
    final api = apiWith(a)..setSession(session);
    await api.sendOrder('o1', idempotencyKey: 'k2');
    expect(a.calls.map((c) => c.method), ['GET', 'POST']);
    expect(a.calls.last.headers['If-Match'], '"v4"');
  });

  test(
    '412 concurrency_conflict: refetch ETag and retry once with the same key',
    () async {
      var posts = 0;
      final a = FakeAdapter((c) {
        if (c.method == 'GET') {
          return json(
            200,
            orderJson(rv: 9),
            h: {
              'etag': ['"v9"'],
            },
          );
        }
        posts++;
        if (posts == 1) {
          return json(412, {
            'type': 'x',
            'title': 'Stale',
            'status': 412,
            'code': 'concurrency_conflict',
          });
        }
        return json(200, orderJson(rv: 10, status: 'SERVED'));
      });
      final api = apiWith(a)..setSession(session);
      final o = await api.markServed('o1', idempotencyKey: 'same-key');
      expect(o.status, 'SERVED');
      final posted = a.calls.where((c) => c.method == 'POST').toList();
      expect(posted, hasLength(2));
      expect(posted.map((c) => c.headers['Idempotency-Key']).toSet(), {
        'same-key',
      });
      expect(posted.last.headers['If-Match'], '"v9"');
    },
  );

  test(
    '202 ApprovalOutcome maps to a pending approval; X-Step-Up-Token is forwarded',
    () async {
      final a = FakeAdapter(
        (c) => c.method == 'GET'
            ? json(
                200,
                orderJson(),
                h: {
                  'etag': ['"v1"'],
                },
              )
            : json(202, {
                'status': 'PENDING_APPROVAL',
                'approval': {
                  'id': 'ap1',
                  'action': 'order.void',
                  'entityType': 'order',
                  'entityId': 'o1',
                  'status': 'PENDING',
                  'requestedAt': '2026-09-23T10:00:00Z',
                  'reason': 'x',
                },
                'order': orderJson(status: 'PENDING_APPROVAL'),
              }),
      );
      final api = apiWith(a)..setSession(session);
      final r = await api.voidOrder(
        'o1',
        reason: 'Guest left',
        stepUpToken: 'su-1',
        idempotencyKey: 'k',
      );
      expect(r.isPending, isTrue);
      expect(r.approval!.id, 'ap1');
      expect(r.approval!.permission, 'order.void.approve');
      expect(r.order!.awaitingApproval, isTrue);
      final post = a.calls.firstWhere((c) => c.method == 'POST');
      expect(post.headers['X-Step-Up-Token'], 'su-1');
      expect((post.body! as Map)['reason'], 'Guest left');
    },
  );

  test(
    'RFC7807 problem+json becomes ApiProblem with the stable code',
    () async {
      final a = FakeAdapter(
        (c) => json(403, {
          'type': 'https://api/problems/permission_denied',
          'title': 'Forbidden',
          'status': 403,
          'code': 'permission_denied',
          'detail': 'Missing order.void.execute',
        }),
      );
      final api = apiWith(a)..setSession(session);
      await expectLater(
        api.listTables('f1'),
        throwsA(
          isA<ApiProblem>()
              .having((p) => p.code, 'code', 'permission_denied')
              .having((p) => p.isPermissionDenied, 'denied', isTrue)
              .having(
                (p) => p.message,
                'message',
                'Missing order.void.execute',
              ),
        ),
      );
    },
  );

  test('connection failures become ApiOfflineException', () async {
    final api = HttpR007Api(baseUrl: 'http://127.0.0.1:1');
    await expectLater(api.systemInfo(), throwsA(isA<ApiOfflineException>()));
  });

  test('401 triggers exactly one single-use refresh, then retries', () async {
    var refreshes = 0;
    var listCalls = 0;
    final a = FakeAdapter((c) {
      if (c.path.endsWith('/auth/staff/refresh')) {
        refreshes++;
        return json(200, {
          'accessToken': 'new-tok',
          'refreshToken': 'new-ref',
          'expiresInSeconds': 900,
          'staff': {
            'id': 's1',
            'displayName': 'Amaka',
            'permissions': <String>[],
          },
        });
      }
      listCalls++;
      if (c.headers['Authorization'] == 'Bearer tok') {
        return json(401, {
          'type': 'x',
          'title': 'Expired',
          'status': 401,
          'code': 'token_expired',
        });
      }
      return json(200, {'items': <Object>[], 'nextCursor': null});
    });
    AuthSession? refreshed;
    final api = apiWith(a)
      ..setSession(session, onRefreshed: (s) => refreshed = s);
    expect(await api.listTables('f1'), isEmpty);
    expect(refreshes, 1);
    expect(listCalls, 2);
    expect(refreshed?.accessToken, 'new-tok');
    expect(refreshed?.refreshToken, 'new-ref');
  });

  test(
    'login body follows the contract (credentialType, identifier, secret)',
    () async {
      final a = FakeAdapter(
        (c) => json(200, {
          'accessToken': 'a',
          'refreshToken': 'r',
          'expiresInSeconds': 900,
          'staff': {
            'id': 's1',
            'displayName': 'Amaka O.',
            'staffNumber': 'S-0042',
            'roles': ['Wait staff'],
            'permissions': ['order.create', 'order.send'],
            'facilityIds': ['f1'],
          },
          'session': {'id': 'sess1'},
        }),
      );
      final api = apiWith(a)..setDeviceToken('dev');
      final s = await api.loginStaff(
        identifier: 'S-0042',
        secret: '4821',
        credentialType: 'PIN',
      );
      expect(a.calls.single.body, {
        'credentialType': 'PIN',
        'identifier': 'S-0042',
        'secret': '4821',
      });
      expect(a.calls.single.headers.containsKey('Authorization'), isFalse);
      expect(s.staff.can('order.create'), isTrue);
      expect(s.staff.can('order.void.execute'), isFalse);
      expect(s.staff.facilityIds, ['f1']);
      expect(s.sessionId, 'sess1');
    },
  );

  test('NFC login sends no identifier', () async {
    final a = FakeAdapter(
      (c) => json(200, {
        'accessToken': 'a',
        'refreshToken': 'r',
        'expiresInSeconds': 900,
        'staff': {'id': 's1', 'displayName': 'X', 'permissions': <String>[]},
      }),
    );
    await apiWith(
      a,
    ).loginStaff(secret: '04A2246B7C5E80', credentialType: 'NFC_CARD');
    expect(a.calls.single.body, {
      'credentialType': 'NFC_CARD',
      'secret': '04A2246B7C5E80',
    });
  });

  test('register device + system info realtime block', () async {
    final a = FakeAdapter((c) {
      if (c.path.endsWith('/devices/register')) {
        return json(201, {
          'device': {
            'id': 'd1',
            'name': 'Tablet 3',
            'kind': 'MOBILE_TABLET',
            'status': 'ACTIVE',
            'homeFacilityId': null,
          },
          'deviceToken': 'secret-device-token',
        });
      }
      return json(200, {
        'service': '007resort-api',
        'apiVersion': 'v1',
        'deploymentMode': 'local',
        'minClientVersion': {'mobile': '0.1.0'},
        'realtime': {
          'scheme': 'ws',
          'host': '192.168.1.10',
          'port': 8081,
          'appKey': 'k',
        },
      });
    });
    final api = apiWith(a);
    final d = await api.registerDevice(
      name: 'Tablet 3',
      kind: 'MOBILE_TABLET',
      hardwareId: 'hw',
      registrationCode: 'ABC-123',
      idempotencyKey: 'i',
    );
    expect(d.deviceId, 'd1');
    expect(d.deviceToken, 'secret-device-token');
    expect(d.mode.apiValue, 'ATTENDANT'); // no home facility => shared pool
    final body = a.calls.first.body! as Map;
    expect(body['registrationCode'], 'ABC-123');
    expect(body['kind'], 'MOBILE_TABLET');
    final info = await api.systemInfo();
    expect(info.realtime!.port, 8081);
    expect(info.realtime!.appKey, 'k');
    expect(info.minMobileVersion, '0.1.0');
  });

  test(
    'redeem: 200 result codes are results, 404 is NOT RECOGNISED, network is an error',
    () async {
      final results = <ResponseBody Function()>[
        () => json(200, {
          'result': 'USED',
          'entitlementId': 'e1',
          'message': 'Already used',
        }),
        () => json(404, {
          'type': 'x',
          'title': 'nf',
          'status': 404,
          'code': 'not_found',
        }),
      ];
      var i = 0;
      final a = FakeAdapter((c) => results[i++]());
      final api = apiWith(a)..setSession(session);
      final r1 = await api.redeem(
        qrToken: 'tok/1',
        facilityId: 'f',
        idempotencyKey: 'k',
      );
      expect(r1.outcome, ScanOutcome.used);
      expect(
        a.calls.first.path,
        contains('/entitlement-tokens/tok%2F1/redeem'),
      );
      expect(a.calls.first.body, {'action': 'ENTRY', 'facilityId': 'f'});
      final r2 = await api.redeem(
        qrToken: 'zzz',
        facilityId: 'f',
        idempotencyKey: 'k2',
      );
      expect(r2.outcome, ScanOutcome.unknown);
    },
  );

  test('facility tree is flattened; unknown fields are ignored', () async {
    final a = FakeAdapter(
      (c) => json(200, {
        'items': [
          {
            'id': 'root',
            'name': 'Site',
            'kind': 'SITE',
            'status': 'ACTIVE',
            'brandNewField': 1,
            'children': [
              {
                'id': 'r1',
                'name': 'Restaurant',
                'kind': 'RESTAURANT',
                'status': 'ACTIVE',
                'children': <Object>[],
              },
              {
                'id': 'x',
                'name': 'Closed',
                'kind': 'BAR',
                'status': 'INACTIVE',
                'children': <Object>[],
              },
            ],
          },
        ],
      }),
    );
    final api = apiWith(a)..setSession(session);
    final f = await api.listFacilities();
    expect(f.map((x) => x.id), ['root', 'r1']);
  });

  test('device mode resolution from kind + home facility kind', () {
    DeviceIdentity d(String kind, {String? home, String? homeKind}) =>
        DeviceIdentity(
          deviceId: 'd',
          deviceToken: 't',
          kind: kind,
          homeFacilityId: home,
          homeFacilityKind: homeKind,
        );
    expect(d('MOBILE_TABLET').mode.apiValue, 'ATTENDANT');
    expect(
      d('MOBILE_TABLET', home: 'f', homeKind: 'RESTAURANT').mode.apiValue,
      'SUPERVISOR',
    );
    expect(
      d('MOBILE_TABLET', home: 'f', homeKind: 'SPORTS_STORE').mode.apiValue,
      'SPORTS_STORE',
    );
    expect(d('ENTRANCE_SCANNER').mode.apiValue, 'SPORTS_ENTRANCE');
    // unresolved facility kind never unlocks a UI
    expect(d('MOBILE_TABLET', home: 'f').mode.apiValue, 'UNREGISTERED');
    expect(d('POS_TERMINAL').mode.apiValue, 'UNREGISTERED');
  });
}
