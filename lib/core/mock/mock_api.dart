import 'dart:async';

import 'package:uuid/uuid.dart';

import '../api/r007_api.dart';
import '../models/models.dart';
import '../util/json.dart';
import '../util/money.dart';
import 'mock_seed.dart';

class _Line {
  _Line({
    required this.id,
    required this.productId,
    required this.name,
    required this.quantity,
    required this.unitMinor,
    this.notes,
  });
  final String id;
  final String productId;
  final String name;
  final int quantity;
  BigInt unitMinor;
  final String? notes;
  String status = LineStatus.pending;
  BigInt discountMinor = BigInt.zero;
  bool comp = false;

  BigInt get totalMinor {
    if (status == LineStatus.voided || comp) return BigInt.zero;
    final t = unitMinor * BigInt.from(quantity) - discountMinor;
    return t.isNegative ? BigInt.zero : t;
  }

  OrderLine toModel() => OrderLine(
    id: id,
    productId: productId,
    name: name,
    quantity: quantity,
    unitPrice: Money.fromMinor(unitMinor),
    lineTotal: Money.fromMinor(totalMinor),
    status: status,
    notes: notes,
  );
}

class _Order {
  _Order({
    required this.id,
    required this.facilityId,
    required this.number,
    required this.createdBy,
    required this.createdById,
    this.tabId,
    this.tableId,
    this.customerName,
  });
  final String id;
  final String facilityId;
  final String number;
  final String createdBy;
  final String createdById;
  String? tabId;
  String? tableId;
  String? customerName;
  String status = OrderStatus.draft;
  String? statusBeforeApproval;
  String? pendingApprovalId;
  int rowVersion = 1;
  final DateTime createdAt = DateTime.now().toUtc();
  final List<_Line> lines = [];
  BigInt get totalMinor => lines.fold(BigInt.zero, (a, l) => a + l.totalMinor);
}

class _Tab {
  _Tab({
    required this.id,
    required this.facilityId,
    this.tableId,
    this.customerName,
  });
  final String id;
  final String facilityId;
  final String? tableId;
  final String? customerName;
  String status = 'OPEN';
}

class _Appr {
  _Appr({
    required this.id,
    required this.action,
    required this.orderId,
    required this.facilityId,
    required this.summary,
    required this.reason,
    required this.amount,
    required this.requestedBy,
    required this.requestedById,
    required this.permission,
    this.lineId,
    this.kind,
    this.value,
  }) : requestedAt = DateTime.now().toUtc();
  final String id;
  final String action;
  final String orderId;
  final String facilityId;
  final String summary;
  final String reason;
  final String amount;
  final String requestedBy;
  final String requestedById;
  final String permission;
  final String? lineId;
  final String? kind;
  final String? value;
  final DateTime requestedAt;
  String status = 'PENDING';
  String? note;

  Approval toModel() => Approval(
    id: id,
    action: action,
    status: status,
    entityType: 'order',
    entityId: orderId,
    summary: summary,
    amount: amount,
    reason: reason,
    requestedByName: requestedBy,
    requestedAt: requestedAt,
    decisionNote: note,
    requiredPermission: permission,
  );
}

class _EntItem {
  _EntItem(
    this.id,
    this.kind,
    this.name,
    this.qty, {
    this.facilityId = 'f-sports-entrance',
  });
  final String id;
  final String kind;
  final String name;
  final int qty;
  final String facilityId;
  int released = 0;
  int returned = 0;
  int redeemed = 0;
}

class _Ent {
  _Ent({
    required this.id,
    required this.qrToken,
    required this.holder,
    required this.facilityId,
    required this.items,
    this.status = 'ACTIVE',
    this.validFrom,
    this.validUntil,
  });
  final String id;
  final String qrToken;
  final String holder;
  final String facilityId;
  String status;
  final DateTime? validFrom;
  final DateTime? validUntil;
  final List<_EntItem> items;
}

/// Built-in demo server. Implements the same [R007Api] the real HTTP client
/// implements, with realistic seeded data and simulated kitchen/bar progress,
/// approvals, entitlement redemption and connectivity loss - so the SAME UI
/// runs unmodified against either backend. Behaviour follows the API contract
/// (202 approval outcomes, step-up, idempotent replays, 200 scan results).
class MockR007Api implements R007Api {
  MockR007Api({
    this.latency = const Duration(milliseconds: 250),
    this.autoProgress = true,
    this.stepDelay = const Duration(seconds: 4),
  }) {
    _seed();
  }

  /// Simulated round-trip latency (zero in tests).
  final Duration latency;

  /// When true, sent orders progress ACCEPTED -> IN_PROGRESS -> READY on timers.
  final bool autoProgress;
  final Duration stepDelay;

  static const _uuid = Uuid();

  /// Simulate the tablet losing Wi-Fi / the local server being unreachable.
  bool offline = false;
  final _offlineCtl = StreamController<bool>.broadcast();
  Stream<bool> get offlineChanges => _offlineCtl.stream;
  void setOffline(bool v) {
    offline = v;
    _offlineCtl.add(v);
  }

  final _events = StreamController<RealtimeEvent>.broadcast();

  MockStaff? _staff;
  final Map<String, dynamic> _idem = {};
  final Map<String, _Order> _orders = {};
  final Map<String, _Tab> _tabs = {};
  final Map<String, _Appr> _approvals = {};
  final Map<String, _Ent> _ents = {};
  final Map<String, Checkout> _checkouts = {};
  final Map<String, DeviceIdentity> _devices = {};
  final Set<String> _occupied = {};
  final Map<String, String> _stepUps = {}; // token -> approver staff id
  int _orderNo = 1000;
  final List<Timer> _timers = [];

  @override
  String get baseUrl => 'mock://007resort';

  @override
  void setDeviceToken(String? token) {}

  @override
  void setSession(
    AuthSession? session, {
    void Function(AuthSession)? onRefreshed,
  }) {
    _staff = session == null
        ? null
        : mockStaff.where((s) => s.id == session.staff.id).firstOrNull;
  }

  Future<T> _call<T>(T Function() body) async {
    if (offline) throw const ApiOfflineException('Simulated network drop');
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (offline) throw const ApiOfflineException('Simulated network drop');
    return body();
  }

  /// Idempotent replay: same key returns the original result.
  T _once<T>(String key, T Function() body) {
    if (_idem.containsKey(key)) return _idem[key] as T;
    final r = body();
    _idem[key] = r;
    return r;
  }

  MockStaff get _me =>
      _staff ??
      (throw const ApiProblem(
        status: 401,
        code: 'unauthenticated',
        title: 'Sign in required',
      ));

  void _require(String perm) {
    if (!_me.permissions.contains(perm)) {
      throw ApiProblem(
        status: 403,
        code: 'permission_denied',
        title: 'Permission denied',
        detail: 'You do not have permission: $perm',
      );
    }
  }

  // -------------------------------------------------------------- seeding

  void _seed() {
    final now = DateTime.now().toUtc();
    void ent(
      String tok,
      String holder,
      String fac, {
      String status = 'ACTIVE',
      DateTime? from,
      DateTime? until,
      int redeemed = 0,
    }) {
      final item = _EntItem(
        'i-$tok',
        'ACCESS',
        'Sports Arena entry',
        1,
        facilityId: fac,
      )..redeemed = redeemed;
      _ents[tok] = _Ent(
        id: 'ent-$tok',
        qrToken: tok,
        holder: holder,
        facilityId: fac,
        status: status,
        validFrom: from,
        validUntil: until,
        items: [item],
      );
    }

    final tomorrow = now.add(const Duration(days: 1));
    ent(
      'R007-DEMO-VALID-1',
      'Adaeze N. (adult)',
      'f-sports-entrance',
      until: tomorrow,
    );
    ent(
      'R007-DEMO-VALID-2',
      'Adaeze N. (child)',
      'f-sports-entrance',
      until: tomorrow,
    );
    ent('R007-DEMO-USED', 'Tunde A.', 'f-sports-entrance', redeemed: 1);
    ent(
      'R007-DEMO-EXPIRED',
      'Kelechi O.',
      'f-sports-entrance',
      until: now.subtract(const Duration(days: 2)),
    );
    ent('R007-DEMO-WRONG', 'Pool guest', 'f-pool');
    ent(
      'R007-DEMO-FUTURE',
      'Ifeanyi M.',
      'f-sports-entrance',
      from: now.add(const Duration(days: 3)),
    );
    ent(
      'R007-DEMO-CANCELLED',
      'Bisi K.',
      'f-sports-entrance',
      status: 'CANCELLED',
    );
    _ents['R007-DEMO-STORE-1'] = _Ent(
      id: 'ent-store-1',
      qrToken: 'R007-DEMO-STORE-1',
      holder: 'Emeka U.',
      facilityId: 'f-sports-entrance',
      validUntil: tomorrow,
      items: [
        _EntItem('i-court', 'ACCESS', 'Tennis court - 1 hour', 1),
        _EntItem(
          'i-racket',
          'RENTAL',
          'Tennis racket (rental)',
          2,
          facilityId: 'f-sports-store',
        ),
        _EntItem(
          'i-water',
          'ITEM',
          'Bottled water',
          3,
          facilityId: 'f-sports-store',
        ),
      ],
    );
    _ents['R007-DEMO-STORE-2'] = _Ent(
      id: 'ent-store-2',
      qrToken: 'R007-DEMO-STORE-2',
      holder: 'Team Eagles',
      facilityId: 'f-sports-entrance',
      validUntil: tomorrow,
      items: [
        _EntItem('i-court2', 'ACCESS', 'Football pitch - 90 min', 1),
        _EntItem(
          'i-ball',
          'RENTAL',
          'Football (rental)',
          1,
          facilityId: 'f-sports-store',
        ),
        _EntItem(
          'i-bibs',
          'RENTAL',
          'Training bibs set (rental)',
          1,
          facilityId: 'f-sports-store',
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- system

  @override
  Future<SystemInfo> systemInfo() => _call(
    () => const SystemInfo(
      service: '007resort-mock',
      apiVersion: 'v1',
      deploymentMode: 'mock',
    ),
  );

  // --------------------------------------------------------------- devices

  @override
  Future<DeviceIdentity> registerDevice({
    required String name,
    required String kind,
    required String hardwareId,
    required String registrationCode,
    String? mode,
    required String idempotencyKey,
  }) => _call(
    () => _once(idempotencyKey, () {
      final e = mockEnrolmentCodes[registrationCode.trim().toUpperCase()];
      if (e == null) {
        throw const ApiProblem(
          status: 422,
          code: 'validation_failed',
          title: 'Registration code not recognised',
          detail:
              'Check the code with IT. (Mock codes: ATT-2026, SUP-2026, ENT-2026, STO-2026)',
        );
      }
      final id = _uuid.v4();
      final home = mockFacilities
          .where((f) => f.id == e.homeFacilityId)
          .firstOrNull;
      final d = DeviceIdentity(
        deviceId: id,
        deviceToken: 'mock-device-${_uuid.v4()}',
        kind: e.kind,
        name: name,
        modeValue: e.mode,
        homeFacilityId: home?.id,
        homeFacilityKind: home?.kind,
        homeFacilityCode: home?.code,
        homeFacilityName: home?.name,
      );
      _devices[id] = d;
      return d;
    }),
  );

  @override
  Future<DeviceIdentity> getDevice(String deviceId) => _call(() {
    final d = _devices[deviceId];
    if (d == null) {
      throw const ApiProblem(
        status: 404,
        code: 'not_found',
        title: 'Device not registered',
      );
    }
    return d;
  });

  @override
  Future<Facility> getFacility(String facilityId) => _call(
    () => mockFacilities.firstWhere(
      (f) => f.id == facilityId,
      orElse: () => throw const ApiProblem(
        status: 404,
        code: 'not_found',
        title: 'Facility not found',
      ),
    ),
  );

  // ------------------------------------------------------------------ auth

  MockStaff? _byCredential(String? identifier, String secret, String type) {
    if (type == 'NFC_CARD') {
      return mockStaff
          .where((s) => s.nfcUid.toLowerCase() == secret.trim().toLowerCase())
          .firstOrNull;
    }
    final id = (identifier ?? '').trim().toLowerCase();
    final s = mockStaff
        .where((x) => x.username == id || x.staffNumber == id)
        .firstOrNull;
    return (s != null && s.pin == secret) ? s : null;
  }

  @override
  Future<AuthSession> loginStaff({
    String? identifier,
    required String secret,
    required String credentialType,
  }) => _call(() {
    final staff = _byCredential(identifier, secret, credentialType);
    if (staff == null) {
      throw const ApiProblem(
        status: 401,
        code: 'invalid_credentials',
        title: 'Invalid credentials',
        detail:
            'Wrong username/staff number or PIN. (Mock: amaka/1234, ngozi/9999, sports1/5555)',
      );
    }
    return AuthSession(
      accessToken: 'mock-access-${staff.id}',
      refreshToken: 'mock-refresh-${staff.id}',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 8)),
      staff: staff.toStaff(),
      sessionId: _uuid.v4(),
    );
  });

  @override
  Future<void> logout() async {
    _staff = null;
  }

  @override
  Future<StepUp> stepUp({
    String? identifier,
    required String secret,
    required String credentialType,
    required String permission,
    String? entityType,
    String? entityId,
  }) => _call(() {
    final who =
        (identifier == null || identifier.isEmpty) &&
            credentialType != 'NFC_CARD'
        ? (_me.pin == secret ? _me : null)
        : _byCredential(identifier, secret, credentialType);
    if (who == null) {
      throw const ApiProblem(
        status: 401,
        code: 'invalid_credentials',
        title: 'Wrong PIN',
      );
    }
    if (!who.permissions.contains(permission)) {
      throw ApiProblem(
        status: 403,
        code: 'permission_denied',
        title: 'Permission denied',
        detail: '${who.name} cannot authorise this ($permission).',
      );
    }
    final token = 'stepup-${_uuid.v4()}';
    _stepUps[token] = who.id;
    return StepUp(token: token, approverName: who.name);
  });

  // -------------------------------------------------------------- checkout

  @override
  Future<List<Facility>> listFacilities() => _call(
    () => mockFacilities
        .where((f) => mockCheckoutFacilityIds.contains(f.id))
        .toList(),
  );

  @override
  Future<FacilityRules> getRules(String facilityId) =>
      _call(() => const FacilityRules());

  @override
  Future<Checkout> checkoutDevice({
    required String deviceId,
    required String staffId,
    required String facilityId,
    String? shiftId,
    required String idempotencyKey,
  }) => _call(
    () => _once(idempotencyKey, () {
      _me;
      if (_checkouts.containsKey(deviceId)) {
        throw const ApiProblem(
          status: 409,
          code: 'concurrency_conflict',
          title: 'Device already checked out',
        );
      }
      final f = mockFacilities.firstWhere(
        (x) => x.id == facilityId,
        orElse: () => throw const ApiProblem(
          status: 422,
          code: 'validation_failed',
          title: 'Unknown facility',
        ),
      );
      final c = Checkout(
        facility: f,
        staffId: staffId,
        checkedOutAt: DateTime.now().toUtc(),
      );
      _checkouts[deviceId] = c;
      return c;
    }),
  );

  @override
  Future<void> checkinDevice({
    required String deviceId,
    required String idempotencyKey,
  }) => _call(() => _checkouts.remove(deviceId));

  // --------------------------------------------------------------- catalog

  @override
  Future<Catalog> getCatalog(String facilityId) => _call(() {
    final food = facilityId == 'f-restaurant' || facilityId == 'f-indoor';
    return food
        ? const Catalog(
            categories: mockFoodCategories,
            products: mockFoodProducts,
          )
        : const Catalog(
            categories: mockBarCategories,
            products: mockBarProducts,
          );
  });

  Product? _product(String id) => [
    ...mockFoodProducts,
    ...mockBarProducts,
  ].where((p) => p.id == id).firstOrNull;

  bool _open(_Order o) =>
      o.status != OrderStatus.settled && o.status != OrderStatus.voided;

  String _tableLabel(String tableId) {
    final m = RegExp(r'^tbl-(.+)-(\d+)$').firstMatch(tableId);
    return m == null ? tableId : 'T${m.group(2)}';
  }

  @override
  Future<List<TableInfo>> listTables(String facilityId) => _call(() {
    if (mockNoTableFacilities.contains(facilityId) ||
        !mockCheckoutFacilityIds.contains(facilityId)) {
      return <TableInfo>[];
    }
    return [
      for (var i = 1; i <= 8; i++)
        () {
          final id = 'tbl-$facilityId-$i';
          final tab = _tabs.values
              .where((t) => t.tableId == id && t.status == 'OPEN')
              .firstOrNull;
          final orders = _orders.values
              .where((o) => o.tableId == id && _open(o))
              .toList();
          return TableInfo(
            id: id,
            name: 'T$i',
            status: (tab != null || orders.isNotEmpty || _occupied.contains(id))
                ? 'OCCUPIED'
                : 'FREE',
            tabId: tab?.id,
            openOrderIds: orders.map((o) => o.id).toList(),
          );
        }(),
    ];
  });

  @override
  Future<void> openTable(String tableId, {required String idempotencyKey}) =>
      _call(
        () => _once(idempotencyKey, () {
          _require('order.create');
          _occupied.add(tableId);
          _events.add(
            RealtimeEvent('table.updated', {
              'facilityId': _facilityOfTable(tableId),
            }),
          );
        }),
      );

  String _facilityOfTable(String tableId) =>
      RegExp(r'^tbl-(.+)-\d+$').firstMatch(tableId)?.group(1) ?? '';

  TabInfo _tabModel(_Tab t) {
    final orders = _orders.values.where((o) => o.tabId == t.id).toList();
    return TabInfo(
      id: t.id,
      tableId: t.tableId,
      customerName: t.customerName,
      status: t.status,
      orderIds: orders.map((o) => o.id).toList(),
      total: Money.fromMinor(
        orders.fold(BigInt.zero, (a, o) => a + o.totalMinor),
      ),
    );
  }

  @override
  Future<TabInfo> openTab({
    required String id,
    required String facilityId,
    String? tableId,
    String? customerName,
    required String idempotencyKey,
  }) => _call(
    () => _once(idempotencyKey, () {
      _require('tab.open');
      final t =
          _tabs[id] ??
          _Tab(
            id: id,
            facilityId: facilityId,
            tableId: tableId,
            customerName: customerName,
          );
      _tabs[id] = t;
      _events.add(RealtimeEvent('table.updated', {'facilityId': facilityId}));
      return _tabModel(t);
    }),
  );

  @override
  Future<List<TabInfo>> listTabs(String facilityId) => _call(
    () => _tabs.values
        .where((t) => t.facilityId == facilityId && t.status == 'OPEN')
        .map(_tabModel)
        .toList(),
  );

  // ---------------------------------------------------------------- orders

  Order _orderModel(_Order o) => Order(
    id: o.id,
    status: o.status,
    facilityId: o.facilityId,
    tabId: o.tabId,
    tableId: o.tableId,
    tableLabel: o.tableId == null ? null : _tableLabel(o.tableId!),
    customerName: o.customerName ?? _tabs[o.tabId]?.customerName,
    lines: o.lines.map((l) => l.toModel()).toList(),
    subtotal: Money.fromMinor(o.totalMinor),
    taxTotal: '0.00',
    total: Money.fromMinor(o.totalMinor),
    balanceDue: Money.fromMinor(o.totalMinor),
    createdAt: o.createdAt,
    createdByName: o.createdBy,
    createdByStaffId: o.createdById,
    number: o.number,
    rowVersion: o.rowVersion,
    pendingApprovalId: o.pendingApprovalId,
  );

  _Order _getOrder(String id) =>
      _orders[id] ??
      (throw const ApiProblem(
        status: 404,
        code: 'not_found',
        title: 'Order not found',
      ));

  void _bump(_Order o) {
    o.rowVersion++;
    _events.add(
      RealtimeEvent('order.updated', {
        'facilityId': o.facilityId,
        'order': {'id': o.id, 'number': o.number, 'status': o.status},
        'rowVersion': o.rowVersion,
      }),
    );
  }

  @override
  Future<Order> createOrder(
    OrderDraft draft, {
    required String idempotencyKey,
  }) => _call(
    () => _once(idempotencyKey, () {
      _require('order.create');
      if (draft.lines.isEmpty) {
        throw const ApiProblem(
          status: 422,
          code: 'validation_failed',
          title: 'An order needs at least one line',
        );
      }
      final o = _Order(
        id: draft.id,
        facilityId: draft.facilityId,
        number: 'ORD-${++_orderNo}',
        createdBy: _me.name,
        createdById: _me.id,
        tabId: draft.tabId,
        tableId: draft.tableId,
        customerName: draft.customerName,
      );
      for (final l in draft.lines) {
        final p = _product(l.productId);
        if (p == null) {
          throw ApiProblem(
            status: 422,
            code: 'validation_failed',
            title: 'Unknown product ${l.productId}',
          );
        }
        if (!p.available) {
          throw ApiProblem(
            status: 409,
            code: 'insufficient_stock',
            title: '${p.name} is not available',
          );
        }
        var unit = Money.toMinor(p.price);
        for (final g in p.modifierGroups) {
          for (final opt in g.options) {
            if (l.modifierOptionIds.contains(opt.id)) {
              unit += Money.toMinor(opt.priceDelta);
            }
          }
        }
        o.lines.add(
          _Line(
            id: l.lineId,
            productId: p.id,
            name: p.name,
            quantity: l.quantity,
            unitMinor: unit,
            notes: l.notes,
          ),
        );
      }
      if (o.tableId != null) _occupied.add(o.tableId!);
      _orders[o.id] = o;
      _bump(o);
      return _orderModel(o);
    }),
  );

  @override
  Future<Order> sendOrder(String orderId, {required String idempotencyKey}) =>
      _call(
        () => _once(idempotencyKey, () {
          _require('order.send');
          final o = _getOrder(orderId);
          if (o.status != OrderStatus.draft) {
            throw const ApiProblem(
              status: 409,
              code: 'order_state_invalid',
              title: 'Order was already sent',
            );
          }
          o.status = OrderStatus.sent;
          for (final l in o.lines) {
            l.status = LineStatus.routed;
          }
          _bump(o);
          if (autoProgress) _progress(o);
          return _orderModel(o);
        }),
      );

  void _recompute(_Order o) {
    if (o.status == OrderStatus.voided ||
        o.status == OrderStatus.pendingApproval) {
      return;
    }
    final live = o.lines.where((l) => l.status != LineStatus.voided).toList();
    if (live.isEmpty) {
      o.status = OrderStatus.voided;
    } else if (live.every((l) => l.status == LineStatus.dispensed)) {
      o.status = OrderStatus.served;
    } else if (live.every(
      (l) => l.status == LineStatus.ready || l.status == LineStatus.dispensed,
    )) {
      o.status = OrderStatus.ready;
    } else if (live.any(
      (l) =>
          l.status == LineStatus.accepted ||
          l.status == LineStatus.inProgress ||
          l.status == LineStatus.ready,
    )) {
      o.status = OrderStatus.inPreparation;
    } else {
      o.status = OrderStatus.sent;
    }
  }

  void _progress(_Order o) {
    final steps = [
      LineStatus.accepted,
      LineStatus.inProgress,
      LineStatus.ready,
    ];
    final bar =
        o.lines.isNotEmpty && o.lines.every((l) => isBarProduct(l.productId));
    for (var i = 0; i < steps.length; i++) {
      _timers.add(
        Timer(
          stepDelay * (i + 1) * (bar ? 1 : 2),
          () => advance(o.id, steps[i]),
        ),
      );
    }
  }

  /// Advance every live line to [status] (used by timers and by tests).
  void advance(String orderId, String status) {
    final o = _orders[orderId];
    if (o == null || o.status == OrderStatus.voided) return;
    for (final l in o.lines) {
      if (l.status == LineStatus.voided || l.status == LineStatus.dispensed) {
        continue;
      }
      l.status = status;
    }
    _recompute(o);
    _bump(o);
    if (o.status == OrderStatus.ready) {
      _events.add(
        RealtimeEvent('order.ready', {
          'facilityId': o.facilityId,
          'orderId': o.id,
          'orderNumber': o.number,
          'tableId': o.tableId,
          'tableLabel': o.tableId == null ? null : _tableLabel(o.tableId!),
          'waiterStaffId': o.createdById,
        }),
      );
    }
  }

  @override
  Future<Order> getOrder(String orderId) =>
      _call(() => _orderModel(_getOrder(orderId)));

  @override
  Future<List<Order>> listOrders(String facilityId) => _call(() {
    final l =
        _orders.values
            .where((o) => o.facilityId == facilityId && _open(o))
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return l.map(_orderModel).toList();
  });

  @override
  Future<Order> markServed(String orderId, {required String idempotencyKey}) =>
      _call(
        () => _once(idempotencyKey, () {
          _require('order.serve');
          final o = _getOrder(orderId);
          final ready = o.lines
              .where((l) => l.status == LineStatus.ready)
              .toList();
          if (ready.isEmpty) {
            throw const ApiProblem(
              status: 409,
              code: 'order_state_invalid',
              title: 'Nothing is ready to serve yet',
            );
          }
          for (final l in ready) {
            l.status = LineStatus.dispensed;
          }
          _recompute(o);
          _bump(o);
          return _orderModel(o);
        }),
      );

  // -------------------------------------------------------- sensitive acts

  /// Resolves who authorises: a valid step-up token (approver holds [approvePerm])
  /// or the caller themself holding it. Returns true when authorised inline.
  bool _authorisedInline(String approvePerm, String? stepUpToken) {
    if (stepUpToken != null) {
      final approver = _stepUps.remove(stepUpToken); // single-use
      if (approver == null) {
        throw const ApiProblem(
          status: 403,
          code: 'step_up_required',
          title: 'Supervisor PIN confirmation required',
        );
      }
      final s = mockStaff.firstWhere((x) => x.id == approver);
      if (!s.permissions.contains(approvePerm)) {
        throw const ApiProblem(
          status: 403,
          code: 'permission_denied',
          title: 'That supervisor cannot authorise this',
        );
      }
      return true;
    }
    return _me.permissions.contains(approvePerm);
  }

  SensitiveResult _needApproval(
    _Order o, {
    required String action,
    required String permission,
    String? lineId,
    String? kind,
    String? value,
    required String reason,
    required String summary,
  }) {
    final a = _Appr(
      id: _uuid.v4(),
      action: action,
      orderId: o.id,
      facilityId: o.facilityId,
      summary: summary,
      reason: reason,
      amount: Money.fromMinor(
        lineId == null
            ? o.totalMinor
            : o.lines.firstWhere((l) => l.id == lineId).totalMinor,
      ),
      requestedBy: _me.name,
      requestedById: _me.id,
      permission: permission,
      lineId: lineId,
      kind: kind,
      value: value,
    );
    _approvals[a.id] = a;
    o.statusBeforeApproval ??= o.status;
    o.status = OrderStatus.pendingApproval;
    o.pendingApprovalId = a.id;
    _bump(o);
    _events.add(
      RealtimeEvent('approval.requested', {
        'facilityId': o.facilityId,
        'approval': _apprJson(a),
      }),
    );
    return SensitiveResult.pending(a.toModel(), order: _orderModel(o));
  }

  Json _apprJson(_Appr a) => {
    'id': a.id,
    'action': a.action,
    'status': a.status,
    'entityId': a.orderId,
  };

  void _applyVoid(_Order o) {
    o.status = OrderStatus.voided;
    for (final l in o.lines) {
      l.status = LineStatus.voided;
    }
    o.pendingApprovalId = null;
    _bump(o);
  }

  void _applyAdjust(_Order o, String lineId, String kind, String? value) {
    final l = o.lines.firstWhere((x) => x.id == lineId);
    switch (kind) {
      case 'DISCOUNT_PERCENT':
        final pct = Money.toMinor(value);
        l.discountMinor =
            (l.unitMinor * BigInt.from(l.quantity) * pct) ~/ BigInt.from(10000);
      case 'DISCOUNT_AMOUNT':
        l.discountMinor = Money.toMinor(value);
      case 'COMP':
        l.comp = true;
      case 'PRICE_OVERRIDE':
        l.unitMinor = Money.toMinor(value);
    }
    o.pendingApprovalId = null;
    _bump(o);
  }

  @override
  Future<SensitiveResult> voidOrder(
    String orderId, {
    required String reason,
    String? stepUpToken,
    required String idempotencyKey,
  }) => _call(
    () => _once(idempotencyKey, () {
      final o = _getOrder(orderId);
      // A valid supervisor step-up token authorises inline (contract flow A2 3b).
      if (stepUpToken == null) _require('order.void.execute');
      if (reason.trim().length < 3) {
        throw const ApiProblem(
          status: 422,
          code: 'validation_failed',
          title: 'A reason is required',
        );
      }
      if (_authorisedInline('order.void.approve', stepUpToken)) {
        _applyVoid(o);
        return SensitiveResult.applied(_orderModel(o));
      }
      return _needApproval(
        o,
        action: 'order.void',
        permission: 'order.void.approve',
        reason: reason,
        summary: 'Void order ${o.number}',
      );
    }),
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
  }) => _call(
    () => _once(idempotencyKey, () {
      final o = _getOrder(orderId);
      if (stepUpToken == null) _require('order.discount.execute');
      if (reason.trim().length < 3) {
        throw const ApiProblem(
          status: 422,
          code: 'validation_failed',
          title: 'A reason is required',
        );
      }
      final (action, perm) = switch (kind) {
        'COMP' => ('order.comp', 'order.comp.approve'),
        'PRICE_OVERRIDE' => (
          'order.price_override',
          'order.price_override.approve',
        ),
        _ => ('order.discount', 'order.discount.approve'),
      };
      final line = o.lines.firstWhere((l) => l.id == lineId);
      if (_authorisedInline(perm, stepUpToken)) {
        _applyAdjust(o, lineId, kind, value);
        return SensitiveResult.applied(_orderModel(o));
      }
      final what = switch (kind) {
        'DISCOUNT_PERCENT' => 'Discount $value% on ${line.name}',
        'DISCOUNT_AMOUNT' => 'Discount ${Money.format(value)} on ${line.name}',
        'COMP' => 'Comp ${line.name}',
        _ => 'Price ${Money.format(value)} on ${line.name}',
      };
      return _needApproval(
        o,
        action: action,
        permission: perm,
        lineId: lineId,
        kind: kind,
        value: value,
        reason: reason,
        summary: '$what (${o.number})',
      );
    }),
  );

  // ------------------------------------------------------------- approvals

  @override
  Future<List<Approval>> listApprovals({
    required String scope,
    String? status,
    String? facilityId,
  }) => _call(() {
    final me = _me;
    return (_approvals.values.where((a) {
          if (facilityId != null && a.facilityId != facilityId) return false;
          if ((status ?? 'PENDING') != a.status) return false;
          return scope == 'mine'
              ? a.requestedById == me.id
              : (me.permissions.contains(a.permission) &&
                    a.requestedById != me.id);
        }).toList()..sort((a, b) => b.requestedAt.compareTo(a.requestedAt)))
        .map((a) => a.toModel())
        .toList();
  });

  @override
  Future<Approval> decideApproval(
    String approvalId, {
    required bool approve,
    String? note,
    String? stepUpToken,
    required String idempotencyKey,
  }) => _call(
    () => _once(idempotencyKey, () {
      final a =
          _approvals[approvalId] ??
          (throw const ApiProblem(
            status: 404,
            code: 'not_found',
            title: 'Approval not found',
          ));
      _require(a.permission);
      if (a.status != 'PENDING') {
        throw const ApiProblem(
          status: 409,
          code: 'concurrency_conflict',
          title: 'Already decided',
        );
      }
      if (a.requestedById == _me.id) {
        throw const ApiProblem(
          status: 403,
          code: 'permission_denied',
          title: 'You cannot approve your own request',
        );
      }
      if (stepUpToken != null && _stepUps.remove(stepUpToken) != _me.id) {
        throw const ApiProblem(
          status: 403,
          code: 'step_up_required',
          title: 'PIN confirmation required',
        );
      }
      a.status = approve ? 'APPROVED' : 'REJECTED';
      a.note = note;
      final o = _getOrder(a.orderId);
      if (approve) {
        if (a.action == 'order.void') {
          _applyVoid(o);
        } else {
          o.status = o.statusBeforeApproval ?? OrderStatus.sent;
          _applyAdjust(o, a.lineId!, a.kind!, a.value);
        }
      } else {
        o.status = o.statusBeforeApproval ?? OrderStatus.sent;
        o.pendingApprovalId = null;
        _bump(o);
      }
      o.statusBeforeApproval = null;
      if (o.status != OrderStatus.voided) _recompute(o);
      _events.add(
        RealtimeEvent('approval.decided', {
          'facilityId': a.facilityId,
          'approval': _apprJson(a),
          'applied': approve,
          'orderId': a.orderId,
        }),
      );
      return a.toModel();
    }),
  );

  // ---------------------------------------------------------- entitlements

  Entitlement _entModel(_Ent e) => Entitlement(
    id: e.id,
    qrToken: e.qrToken,
    status: e.status,
    holderName: e.holder,
    items: [
      for (final i in e.items)
        EntitlementItem(
          id: i.id,
          kind: i.kind,
          name: i.name,
          quantity: i.qty,
          facilityId: i.facilityId,
          quantityRedeemed: i.kind == 'ACCESS'
              ? i.redeemed
              : (i.kind == 'ITEM' ? i.released : 0),
          rentalStatus: i.kind == 'RENTAL'
              ? (i.returned > 0
                    ? 'RETURNED'
                    : (i.released > 0 ? 'RELEASED' : 'NOT_RELEASED'))
              : null,
        ),
    ],
  );

  _Ent? _byToken(String t) => _ents[t.trim()];
  _Ent? _byId(String id) => _ents.values.where((e) => e.id == id).firstOrNull;

  @override
  Future<RedeemResult> redeem({
    required String qrToken,
    required String facilityId,
    required String idempotencyKey,
  }) => _call(
    () => _once(idempotencyKey, () {
      _require('ticket.redeem');
      final e = _byToken(qrToken);
      if (e == null) {
        return const RedeemResult(
          outcome: ScanOutcome.unknown,
          message: 'QR code not recognised',
        );
      }
      final access = e.items.firstWhere((i) => i.kind == 'ACCESS');
      final now = DateTime.now().toUtc();
      final ScanOutcome outcome;
      if (e.status == 'CANCELLED') {
        outcome = ScanOutcome.cancelled;
      } else if (e.facilityId != facilityId) {
        outcome = ScanOutcome.wrongFacility;
      } else if (e.validFrom != null && now.isBefore(e.validFrom!)) {
        outcome = ScanOutcome.notYetValid;
      } else if (e.validUntil != null && now.isAfter(e.validUntil!)) {
        outcome = ScanOutcome.expired;
      } else if (access.redeemed >= access.qty) {
        outcome = ScanOutcome.used;
      } else {
        access.redeemed++;
        outcome = ScanOutcome.valid;
      }
      return RedeemResult(
        outcome: outcome,
        entitlementId: e.id,
        holderName: e.holder,
        itemName: access.name,
        remaining: access.qty - access.redeemed,
        validFrom: e.validFrom,
        validUntil: e.validUntil,
        message: switch (outcome) {
          ScanOutcome.valid => 'Entry granted',
          ScanOutcome.used => 'This ticket has already been used',
          ScanOutcome.expired => 'This ticket has expired',
          ScanOutcome.wrongFacility => 'This ticket is for another facility',
          ScanOutcome.notYetValid => 'This ticket is not valid yet',
          _ => 'This ticket was cancelled',
        },
      );
    }),
  );

  @override
  Future<Entitlement> getEntitlementByToken(String qrToken) => _call(() {
    _require('ticket.view');
    final e = _byToken(qrToken);
    if (e == null) {
      throw const ApiProblem(
        status: 404,
        code: 'not_found',
        title: 'QR code not recognised',
      );
    }
    return _entModel(e);
  });

  @override
  Future<Entitlement> releaseItems(
    String entitlementId, {
    required List<String> itemIds,
    String? note,
    required String idempotencyKey,
  }) => _call(
    () => _once(idempotencyKey, () {
      _require('ticket.release');
      final e =
          _byId(entitlementId) ??
          (throw const ApiProblem(
            status: 404,
            code: 'not_found',
            title: 'Entitlement not found',
          ));
      if (e.status == 'CANCELLED') {
        throw const ApiProblem(
          status: 409,
          code: 'ticket_invalid',
          title: 'This entitlement is cancelled',
        );
      }
      final items = e.items.where((i) => itemIds.contains(i.id)).toList();
      if (items.any((i) => i.released >= i.qty)) {
        throw const ApiProblem(
          status: 409,
          code: 'ticket_used',
          title: 'Already released',
          detail:
              'These items were already released. Nothing more to hand over.',
        );
      }
      for (final i in items) {
        i.released = i.qty;
      }
      return _entModel(e);
    }),
  );

  @override
  Future<Entitlement> returnItems(
    String entitlementId, {
    required List<String> itemIds,
    String condition = 'OK',
    String? note,
    required String idempotencyKey,
  }) => _call(
    () => _once(idempotencyKey, () {
      _require('ticket.release');
      final e =
          _byId(entitlementId) ??
          (throw const ApiProblem(
            status: 404,
            code: 'not_found',
            title: 'Entitlement not found',
          ));
      final items = e.items.where((i) => itemIds.contains(i.id)).toList();
      if (items.any((i) => i.released == 0 || i.returned >= i.released)) {
        throw const ApiProblem(
          status: 409,
          code: 'payment_state_invalid',
          title: 'Nothing to return for these items',
        );
      }
      for (final i in items) {
        i.returned = i.released;
      }
      return _entModel(e);
    }),
  );

  // -------------------------------------------------------------- realtime

  @override
  Stream<RealtimeEvent> realtime({
    required String facilityId,
    required String deviceId,
  }) => _events.stream.where(
    (e) => e.data['facilityId'] == null || e.data['facilityId'] == facilityId,
  );

  @override
  void close() {
    for (final t in _timers) {
      t.cancel();
    }
    unawaited(_events.close());
    unawaited(_offlineCtl.close());
  }
}
