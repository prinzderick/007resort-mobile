import 'dart:async';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../models/collection_models.dart';
import '../models/models.dart';
import '../realtime/pusher_client.dart';
import '../util/json.dart';
import 'r007_api.dart';

class _Resp {
  const _Resp(this.status, this.data, this.etag);
  final int status;
  final dynamic data;
  final String? etag;
}

/// Real-server implementation of [R007Api] against the contract of record
/// (`007resort-docs/api/openapi/v1.yaml`, `api/realtime.md`).
class HttpR007Api implements R007Api {
  HttpR007Api({required String baseUrl, Dio? dio})
    : _baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              sendTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              headers: {'Accept': 'application/json'},
              validateStatus: (_) => true, // statuses are mapped below
            ),
          ) {
    _dio.options.baseUrl = '$_baseUrl/api/v1';
  }

  final String _baseUrl;
  final Dio _dio;
  static const _uuid = Uuid();

  String? _deviceToken;
  AuthSession? _session;
  void Function(AuthSession)? _onRefreshed;
  Future<bool>? _refreshing;
  SystemInfo? _info;

  /// Last known ETag per order (`If-Match` for send/serve/void/adjust).
  final Map<String, String> _etags = {};

  @override
  String get baseUrl => _baseUrl;

  @override
  void setDeviceToken(String? token) => _deviceToken = token;

  @override
  void setSession(
    AuthSession? session, {
    void Function(AuthSession)? onRefreshed,
  }) {
    _session = session;
    _onRefreshed = onRefreshed;
  }

  // ------------------------------------------------------------ transport

  Future<_Resp> _raw(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
    bool auth = true,
    bool allowRefresh = true,
  }) async {
    final headers = <String, dynamic>{
      'X-Correlation-Id': _uuid.v4(),
      if (_deviceToken != null) 'X-Device-Token': _deviceToken,
      if (auth && _session != null)
        'Authorization': 'Bearer ${_session!.accessToken}',
      'Idempotency-Key': ?idempotencyKey,
      ...?extraHeaders,
    };
    Response<dynamic> res;
    try {
      res = await _dio.request<dynamic>(
        path,
        data: body,
        queryParameters: query,
        options: Options(method: method, headers: headers),
      );
    } on DioException catch (e) {
      throw ApiOfflineException(e.message ?? 'Network error');
    }
    final status = res.statusCode ?? 0;
    if (status == 401 &&
        auth &&
        allowRefresh &&
        _session != null &&
        await _tryRefresh()) {
      return _raw(
        method,
        path,
        body: body,
        query: query,
        idempotencyKey: idempotencyKey,
        extraHeaders: extraHeaders,
        auth: auth,
        allowRefresh: false,
      );
    }
    if (status >= 200 && status < 300) {
      return _Resp(status, res.data, res.headers.value('etag'));
    }
    final d = res.data;
    if (d is Map<String, dynamic>) throw ApiProblem.fromJson(status, d);
    if (status >= 500 || status == 0) {
      throw ApiProblem(
        status: status,
        code: 'server_error',
        title: 'Server error',
      );
    }
    throw ApiProblem(status: status, title: 'Request failed ($status)');
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
    bool auth = true,
  }) async => (await _raw(
    method,
    path,
    body: body,
    query: query,
    idempotencyKey: idempotencyKey,
    extraHeaders: extraHeaders,
    auth: auth,
  )).data;

  Future<bool> _tryRefresh() {
    return _refreshing ??= () async {
      try {
        final s = _session;
        if (s == null || s.refreshToken.isEmpty) return false;
        final r = await _raw(
          'POST',
          '/auth/staff/refresh',
          body: {'refreshToken': s.refreshToken},
          auth: false,
          allowRefresh: false,
        );
        final next = AuthSession.fromJson(_obj(r.data));
        _session = AuthSession(
          accessToken: next.accessToken,
          refreshToken: next.refreshToken.isEmpty
              ? s.refreshToken
              : next.refreshToken,
          expiresAt: next.expiresAt,
          staff: next.staff.id.isEmpty ? s.staff : next.staff,
          sessionId: next.sessionId ?? s.sessionId,
        );
        _onRefreshed?.call(_session!);
        return true;
      } on Object {
        return false;
      } finally {
        _refreshing = null;
      }
    }();
  }

  Json _obj(dynamic v) => v is Map<String, dynamic> ? v : <String, dynamic>{};
  List<Json> _items(dynamic v) {
    final raw = v is List ? v : (v is Map ? v['items'] : null);
    if (raw is List) return raw.whereType<Map<String, dynamic>>().toList();
    return const [];
  }

  /// Follows `nextCursor` (bounded) and concatenates `items`.
  Future<List<Json>> _listAll(
    String path, {
    Map<String, dynamic>? query,
    int maxPages = 10,
  }) async {
    final all = <Json>[];
    String? cursor;
    for (var i = 0; i < maxPages; i++) {
      final r = await _send(
        'GET',
        path,
        query: {...?query, 'limit': 100, 'cursor': ?cursor},
      );
      all.addAll(_items(r));
      cursor = r is Map ? r['nextCursor'] as String? : null;
      if (cursor == null) break;
    }
    return all;
  }

  // -------------------------------------------------------------- system

  @override
  Future<SystemInfo> systemInfo() async => _info = SystemInfo.fromJson(
    _obj(await _send('GET', '/system/info', auth: false)),
  );

  // -------------------------------------------------------------- devices

  @override
  Future<DeviceIdentity> registerDevice({
    required String name,
    required String kind,
    required String hardwareId,
    required String registrationCode,
    String? mode,
    required String idempotencyKey,
  }) async {
    final r = _obj(
      await _send(
        'POST',
        '/devices/register',
        body: {
          'name': name,
          'kind': kind,
          'mode': ?mode,
          'hardwareId': hardwareId,
          'platform': 'android',
          'appVersion': AppConfig.appVersion,
          'registrationCode': registrationCode,
        },
        idempotencyKey: idempotencyKey,
        auth: false,
      ),
    );
    return DeviceIdentity.fromJson(
      r.obj('device'),
      token: r.str('deviceToken'),
    );
  }

  @override
  Future<DeviceIdentity> getDevice(String deviceId) async {
    final r = _obj(await _send('GET', '/devices/$deviceId'));
    return DeviceIdentity.fromJson(r, token: _deviceToken ?? '');
  }

  @override
  Future<Facility> getFacility(String facilityId) async => Facility.fromJson(
    _obj(await _send('GET', '/organization/facilities/$facilityId')),
  );

  // ----------------------------------------------------------------- auth

  @override
  Future<AuthSession> loginStaff({
    String? identifier,
    required String secret,
    required String credentialType,
  }) async {
    final r = await _send(
      'POST',
      '/auth/staff/login',
      body: {
        'credentialType': credentialType,
        if (identifier != null && identifier.isNotEmpty)
          'identifier': identifier,
        'secret': secret,
      },
      auth: false,
    );
    return AuthSession.fromJson(_obj(r));
  }

  @override
  Future<void> logout() async {
    try {
      await _send(
        'POST',
        '/auth/staff/logout',
        body: const <String, dynamic>{},
      );
    } on ApiProblem {
      // session already gone server-side
    }
  }

  @override
  Future<StepUp> stepUp({
    String? identifier,
    required String secret,
    required String credentialType,
    required String permission,
    String? entityType,
    String? entityId,
  }) async {
    final r = _obj(
      await _send(
        'POST',
        '/auth/staff/step-up',
        body: {
          'credentialType': credentialType,
          if (identifier != null && identifier.isNotEmpty)
            'identifier': identifier,
          'secret': secret,
          'permission': permission,
          'entityType': ?entityType,
          if (entityId != null && entityId.isNotEmpty) 'entityId': entityId,
        },
      ),
    );
    return StepUp(
      token: r.str('stepUpToken'),
      approverName: r.obj('approver').strOrNull('displayName'),
    );
  }

  // -------------------------------------------------------------- checkout

  List<Facility> _flatten(List<Json> nodes) {
    final out = <Facility>[];
    void walk(List<Json> ns) {
      for (final n in ns) {
        if (n.str('status', 'ACTIVE') == 'ACTIVE') {
          out.add(Facility.fromJson(n));
        }
        walk(n.list('children'));
      }
    }

    walk(nodes);
    return out;
  }

  @override
  Future<List<Facility>> listFacilities() async =>
      _flatten(_items(await _send('GET', '/organization/facilities')));

  @override
  Future<FacilityRules> getRules(String facilityId) async {
    try {
      return FacilityRules.fromJson(
        _obj(await _send('GET', '/facilities/$facilityId/capabilities')),
      );
    } on ApiProblem {
      return const FacilityRules();
    }
  }

  @override
  Future<Checkout> checkoutDevice({
    required String deviceId,
    required String staffId,
    required String facilityId,
    String? shiftId,
    required String idempotencyKey,
  }) async {
    final r = _obj(
      await _send(
        'POST',
        '/devices/$deviceId/checkout',
        body: {
          'staffId': staffId,
          'facilityId': facilityId,
          'shiftId': ?shiftId,
        },
        idempotencyKey: idempotencyKey,
      ),
    );
    final c = r.obj('checkout');
    return Checkout(
      facility: Facility(id: c.str('facilityId', facilityId), name: ''),
      staffId: c.strOrNull('staffId') ?? staffId,
      shiftId: c.strOrNull('shiftId') ?? shiftId,
      checkedOutAt: c.date('checkedOutAt'),
    );
  }

  @override
  Future<void> checkinDevice({
    required String deviceId,
    required String idempotencyKey,
  }) async {
    await _send(
      'POST',
      '/devices/$deviceId/checkin',
      body: const <String, dynamic>{},
      idempotencyKey: idempotencyKey,
    );
  }

  // --------------------------------------------------------------- catalog

  @override
  Future<Catalog> getCatalog(String facilityId) async {
    final cats = (await _listAll(
      '/catalog/categories',
    )).map(Category.fromJson).toList();
    final prods =
        (await _listAll('/catalog/products', query: {'facilityId': facilityId}))
            .map(Product.fromJson)
            .where((p) => const {'FOOD', 'DRINK', 'RETAIL'}.contains(p.kind))
            .toList();
    return Catalog(categories: cats, products: prods);
  }

  @override
  Future<List<TableInfo>> listTables(String facilityId) async =>
      (await _listAll(
        '/tables',
        query: {'facilityId': facilityId},
      )).map(TableInfo.fromJson).toList();

  @override
  Future<void> openTable(
    String tableId, {
    required String idempotencyKey,
  }) async {
    await _send(
      'POST',
      '/tables/$tableId/open',
      body: const <String, dynamic>{},
      idempotencyKey: idempotencyKey,
    );
  }

  @override
  Future<TabInfo> openTab({
    required String id,
    required String facilityId,
    String? tableId,
    String? customerName,
    required String idempotencyKey,
  }) async {
    final r = await _send(
      'POST',
      '/tabs',
      body: {
        'id': id,
        'clientCreatedAt': DateTime.now().toUtc().toIso8601String(),
        'facilityId': facilityId,
        'tableId': ?tableId,
        if (customerName != null && customerName.isNotEmpty)
          'customerName': customerName,
      },
      idempotencyKey: idempotencyKey,
    );
    return TabInfo.fromJson(_obj(r));
  }

  @override
  Future<List<TabInfo>> listTabs(String facilityId) async => (await _listAll(
    '/tabs',
    query: {'filter[facilityId]': facilityId, 'filter[status]': 'OPEN'},
  )).map(TabInfo.fromJson).toList();

  // ---------------------------------------------------------------- orders

  Order _order(_Resp r) {
    final o = Order.fromJson(_obj(r.data));
    final tag = r.etag ?? (o.rowVersion > 0 ? '"v${o.rowVersion}"' : null);
    if (tag != null) _etags[o.id] = tag;
    return o;
  }

  Future<String> _etagFor(String orderId, {bool refresh = false}) async {
    if (!refresh && _etags.containsKey(orderId)) return _etags[orderId]!;
    final r = await _raw('GET', '/orders/$orderId');
    _order(r);
    return _etags[orderId] ?? '*';
  }

  /// Mutation on an order with `If-Match`; on a stale ETag refetch and retry
  /// once (same body + same Idempotency-Key, per the offline guidance).
  Future<_Resp> _orderMutation(
    String orderId,
    String method,
    String path, {
    Object? body,
    required String idempotencyKey,
    Map<String, String>? extra,
  }) async {
    Future<_Resp> attempt(bool refresh) async => _raw(
      method,
      path,
      body: body ?? const <String, dynamic>{},
      idempotencyKey: idempotencyKey,
      extraHeaders: {
        'If-Match': await _etagFor(orderId, refresh: refresh),
        ...?extra,
      },
    );
    try {
      return await attempt(false);
    } on ApiProblem catch (e) {
      if (e.status == 412 ||
          e.status == 428 ||
          (e.status == 409 && e.code == 'concurrency_conflict')) {
        return attempt(true);
      }
      rethrow;
    }
  }

  @override
  Future<Order> createOrder(
    OrderDraft draft, {
    required String idempotencyKey,
  }) async => _order(
    await _raw(
      'POST',
      '/orders',
      body: draft.toApi(),
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<Order> addOrderLine(
    String orderId,
    DraftLine line, {
    required String idempotencyKey,
  }) async => _order(
    await _orderMutation(
      orderId,
      'POST',
      '/orders/$orderId/lines',
      body: line.toApi(),
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<Order> removeOrderLine(String orderId, String lineId) async => _order(
    await _orderMutation(
      orderId,
      'DELETE',
      '/orders/$orderId/lines/$lineId',
      idempotencyKey: _uuid.v7(),
    ),
  );

  @override
  Future<Order> sendOrder(
    String orderId, {
    required String idempotencyKey,
  }) async => _order(
    await _orderMutation(
      orderId,
      'POST',
      '/orders/$orderId/send',
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<Order> getOrder(String orderId) async =>
      _order(await _raw('GET', '/orders/$orderId'));

  @override
  Future<List<Order>> listOrders(String facilityId) async {
    final r = await _send(
      'GET',
      '/orders',
      query: {
        'filter[facilityId]': facilityId,
        // Only unsettled orders: a busy outlet settles hundreds a day, which
        // would otherwise push every open order out of the newest-N page.
        'filter[status]':
            'DRAFT,SENT,IN_PREPARATION,READY,SERVED,PENDING_APPROVAL',
        'sort': '-createdAt',
        'limit': 60,
      },
    );
    final open = _items(
      r,
    ).map(Order.fromJson).where((o) => o.isOpen).take(40).toList();
    final detailed = await Future.wait(
      open.map((o) => getOrder(o.id).catchError((Object _) => o)),
    );
    return detailed;
  }

  @override
  Future<Order> markServed(
    String orderId, {
    required String idempotencyKey,
  }) async => _order(
    await _orderMutation(
      orderId,
      'POST',
      '/orders/$orderId/serve',
      idempotencyKey: idempotencyKey,
    ),
  );

  SensitiveResult _sensitive(_Resp r) {
    final j = _obj(r.data);
    if (r.status == 202 || j['approval'] is Map) {
      return SensitiveResult.pending(
        Approval.fromJson(j.obj('approval')),
        order: j['order'] is Map<String, dynamic>
            ? Order.fromJson(j.obj('order'))
            : null,
      );
    }
    return SensitiveResult.applied(_order(r));
  }

  @override
  Future<SensitiveResult> voidOrder(
    String orderId, {
    required String reason,
    String? stepUpToken,
    required String idempotencyKey,
  }) async => _sensitive(
    await _orderMutation(
      orderId,
      'POST',
      '/orders/$orderId/void',
      body: {'reason': reason},
      idempotencyKey: idempotencyKey,
      extra: {'X-Step-Up-Token': ?stepUpToken},
    ),
  );

  @override
  Future<SensitiveResult> adjustLine(
    String orderId,
    String lineId, {
    required String kind,
    String? value,
    required String reason,
    String? stepUpToken,
    required String idempotencyKey,
  }) async => _sensitive(
    await _orderMutation(
      orderId,
      'POST',
      '/orders/$orderId/lines/$lineId/adjustments',
      body: {'kind': kind, 'value': value ?? '0', 'reason': reason},
      idempotencyKey: idempotencyKey,
      extra: {'X-Step-Up-Token': ?stepUpToken},
    ),
  );

  // ------------------------------------------------------------- approvals

  @override
  Future<List<Approval>> listApprovals({
    required String scope,
    String? status,
    String? facilityId,
  }) async => (await _listAll(
    '/approvals',
    query: {
      'scope': scope,
      'filter[status]': ?status,
      'filter[facilityId]': ?facilityId,
    },
    maxPages: 3,
  )).map(Approval.fromJson).toList();

  @override
  Future<Approval> decideApproval(
    String approvalId, {
    required bool approve,
    String? note,
    String? stepUpToken,
    required String idempotencyKey,
  }) async {
    final r = await _send(
      'POST',
      '/approvals/$approvalId/decision',
      body: {
        'decision': approve ? 'APPROVE' : 'REJECT',
        if (note != null && note.isNotEmpty) 'note': note,
        'stepUpToken': ?stepUpToken,
      },
      idempotencyKey: idempotencyKey,
    );
    return Approval.fromJson(_obj(r));
  }

  // ----------------------------------------------------------- entitlements

  String _enc(String code) => Uri.encodeComponent(code);

  @override
  Future<RedeemResult> redeem({
    required String qrToken,
    required String facilityId,
    required String idempotencyKey,
  }) async {
    try {
      final r = await _send(
        'POST',
        '/entitlement-tokens/${_enc(qrToken)}/redeem',
        body: {'action': 'ENTRY', 'facilityId': facilityId},
        idempotencyKey: idempotencyKey,
      );
      return RedeemResult.fromJson(_obj(r));
    } on ApiProblem catch (e) {
      // A definitive "no such token" is a result, not a connectivity error.
      if (e.status == 404 || e.code == 'ticket_invalid') {
        return const RedeemResult(
          outcome: ScanOutcome.unknown,
          message: 'QR code not recognised',
        );
      }
      rethrow;
    }
  }

  @override
  Future<Entitlement> getEntitlementByToken(String qrToken) async =>
      Entitlement.fromJson(
        _obj(await _send('GET', '/entitlement-tokens/${_enc(qrToken)}')),
      );

  @override
  Future<Entitlement> releaseItems(
    String entitlementId, {
    required List<String> itemIds,
    String? note,
    required String idempotencyKey,
  }) async => Entitlement.fromJson(
    _obj(
      await _send(
        'POST',
        '/entitlements/$entitlementId/release',
        body: {'itemIds': itemIds, 'note': ?note},
        idempotencyKey: idempotencyKey,
      ),
    ),
  );

  @override
  Future<Entitlement> returnItems(
    String entitlementId, {
    required List<String> itemIds,
    String condition = 'OK',
    String? note,
    required String idempotencyKey,
  }) async => Entitlement.fromJson(
    _obj(
      await _send(
        'POST',
        '/entitlements/$entitlementId/return',
        body: {'itemIds': itemIds, 'condition': condition, 'note': ?note},
        idempotencyKey: idempotencyKey,
      ),
    ),
  );

  // ------------------------------------------------- waiter collection

  /// Some servers answer with the order, others `{order: {...}}`.
  Json _unwrap(dynamic data, String key) {
    final j = _obj(data);
    return j[key] is Map<String, dynamic> ? j.obj(key) : j;
  }

  @override
  Future<Order> printBill(
    String orderId, {
    required String idempotencyKey,
  }) async {
    final r = await _raw(
      'POST',
      '/orders/$orderId/bill',
      body: const <String, dynamic>{},
      idempotencyKey: idempotencyKey,
    );
    final o = Order.fromJson(_unwrap(r.data, 'order'));
    if (r.etag != null) _etags[o.id] = r.etag!;
    return o;
  }

  @override
  Future<Collection> createCollection(
    CollectionRequest request, {
    required String idempotencyKey,
  }) async {
    final r = await _raw(
      'POST',
      '/orders/${request.orderId}/collections',
      body: request.toApi(),
      idempotencyKey: idempotencyKey,
    );
    final j = _obj(r.data);
    final c = Collection.fromPayment(
      j.obj('payment'),
      payLink: j['payLink'] is Map<String, dynamic> ? j.obj('payLink') : null,
      transferAccount: j['transferAccount'] is Map<String, dynamic>
          ? j.obj('transferAccount')
          : null,
      orderId: request.orderId,
    );
    return c;
  }

  Collection _collection(Json p, {String? orderId}) =>
      Collection.fromPayment(p, orderId: orderId);

  @override
  Future<List<Collection>> listCollections(String orderId) async {
    final r = await _send(
      'GET',
      '/payments',
      query: {'orderId': orderId, 'limit': 50},
    );
    return [
      for (final p in _items(r))
        if (p['collection'] is Map<String, dynamic>)
          _collection(p, orderId: orderId),
    ];
  }

  @override
  Future<List<Collection>> listMyCollections(
    String staffId, {
    required DateTime since,
  }) async {
    final r = await _send(
      'GET',
      '/payments',
      query: {
        'collectedBy': staffId,
        'filter[from]': since.toUtc().toIso8601String(),
        'limit': 100,
      },
    );
    return [
      for (final p in _items(r))
        if (p['collection'] is Map<String, dynamic>) _collection(p),
    ];
  }

  @override
  Future<List<CashHandover>> listHandovers(String staffId) async {
    final r = await _send(
      'GET',
      '/cash-handovers',
      query: {'waiterId': staffId, 'limit': 10},
    );
    return _items(r).map(CashHandover.fromJson).toList();
  }

  @override
  Future<CollectionPolicy> collectionPolicy(
    String staffId, {
    String? facilityId,
  }) async {
    try {
      return CollectionPolicy.fromJson(
        _obj(
          await _send(
            'GET',
            '/staff/$staffId/collection-policy',
            query: {'facilityId': ?facilityId},
          ),
        ),
      );
    } on ApiProblem catch (e) {
      // Older node without the endpoint: the server still enforces policy.
      if (e.status == 404) return CollectionPolicy.permissive;
      rethrow;
    }
  }

  @override
  Future<CashInHand> cashInHand(String staffId) async => CashInHand.fromJson(
    _obj(await _send('GET', '/staff/$staffId/cash-in-hand')),
  );

  @override
  Future<CashHandover> createHandover({
    required String id,
    required String declaredAmount,
    String? note,
    required String idempotencyKey,
  }) async {
    final r = await _raw(
      'POST',
      '/cash-handovers',
      body: {
        'id': id,
        'declaredAmount': declaredAmount,
        if (note != null && note.isNotEmpty) 'note': note,
      },
      idempotencyKey: idempotencyKey,
    );
    return CashHandover.fromJson(_obj(r.data));
  }

  // -------------------------------------------------------------- realtime

  @override
  Stream<RealtimeEvent> realtime({
    required String facilityId,
    required String deviceId,
  }) async* {
    final info = _info ?? await systemInfo();
    final rt = info.realtime;
    final base = Uri.parse(_baseUrl);
    final cfg = realtimeConfigFor(base, rt);
    final client = PusherClient(
      config: cfg,
      channels: [
        'private-facility.$facilityId.orders',
        'private-device.$deviceId',
      ],
      authorize: (socketId, channel) async {
        final r = await _send(
          'POST',
          '/broadcasting/auth',
          body: {'socket_id': socketId, 'channel_name': channel},
        );
        return _obj(r).str('auth');
      },
    );
    yield* client.events;
  }

  @override
  void close() => _dio.close(force: true);
}

/// Reverb host as published by the node may be a server-local address
/// (`127.0.0.1`, `0.0.0.0`, `localhost`) that a tablet cannot reach: in that
/// case use the host the tablet already uses for the API.
RealtimeConfig realtimeConfigFor(Uri apiBase, RealtimeInfo? rt) {
  if (rt == null) {
    return RealtimeConfig(host: apiBase.host);
  }
  const local = {'', '0.0.0.0', 'localhost', '127.0.0.1', '::1'};
  return RealtimeConfig(
    host: local.contains(rt.host) ? apiBase.host : rt.host,
    port: rt.port,
    appKey: rt.appKey,
    scheme: rt.scheme,
  );
}
