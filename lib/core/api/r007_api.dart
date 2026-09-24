import '../models/collection_models.dart';
import '../models/models.dart';
import '../util/json.dart';

/// Thrown when the server is unreachable (no route, timeout, DNS, refused).
/// This is the ONLY exception that may cause an operation to be queued.
class ApiOfflineException implements Exception {
  const ApiOfflineException([this.message = 'Cannot reach the server']);
  final String message;
  @override
  String toString() => 'ApiOfflineException: $message';
}

/// RFC 7807 problem+json returned by the server, with the stable `code`.
class ApiProblem implements Exception {
  const ApiProblem({
    required this.status,
    this.code = 'unknown',
    this.title = 'Request failed',
    this.detail,
    this.errors = const {},
    this.approvalId,
  });

  factory ApiProblem.fromJson(int status, Json j) => ApiProblem(
    status: status,
    code: j.str('code', 'unknown'),
    title: j.str('title', 'Request failed'),
    detail: j.strOrNull('detail'),
    errors: j.obj('errors'),
    approvalId: j.strOrNull('approvalId'),
  );

  final int status;
  final String code;
  final String title;
  final String? detail;
  final Map<String, dynamic> errors;
  final String? approvalId;

  bool get isUnauthorized => status == 401;
  bool get isPermissionDenied => status == 403 && code == 'permission_denied';
  bool get isApprovalRequired =>
      code == 'approval_required' || code == 'approval_pending';
  bool get isStepUpRequired => code == 'step_up_required';
  bool get isConflict => status == 409 || status == 412;

  /// Human message for the UI (never leaks stack traces).
  String get message => detail ?? title;

  @override
  String toString() => 'ApiProblem($status, $code): $message';
}

// ----------------------------------------------------------- request DTOs

class DraftLine {
  const DraftLine({
    required this.lineId,
    required this.productId,
    required this.name,
    required this.quantity,
    required this.estUnitPrice,
    this.modifierOptionIds = const [],
    this.modifierNames = const [],
    this.note,
  });

  factory DraftLine.fromJson(Json j) => DraftLine(
    lineId: j.str('lineId'),
    productId: j.str('productId'),
    name: j.str('name'),
    quantity: j.intOr('quantity', 1),
    estUnitPrice: j.str('estUnitPrice', '0.00'),
    modifierOptionIds: [
      for (final m in (j['modifierOptionIds'] as List? ?? const []))
        m.toString(),
    ],
    modifierNames: [
      for (final m in (j['modifierNames'] as List? ?? const [])) m.toString(),
    ],
    note: j.strOrNull('note'),
  );

  final String lineId;
  final String productId;
  final String name;
  final int quantity;

  /// Catalog price snapshot for DISPLAY ONLY (labelled "est."); the server
  /// re-prices every line and is the source of truth.
  final String estUnitPrice;
  final List<String> modifierOptionIds;
  final List<String> modifierNames;
  final String? note;

  /// Free text sent to the server as the line `notes` (modifiers + note).
  String? get notes {
    final parts = [
      ...modifierNames,
      if (note != null && note!.trim().isNotEmpty) note!.trim(),
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// Persisted (queue) form, includes display fields.
  Json toJson() => {
    'lineId': lineId,
    'productId': productId,
    'name': name,
    'quantity': quantity,
    'estUnitPrice': estUnitPrice,
    'modifierOptionIds': modifierOptionIds,
    'modifierNames': modifierNames,
    'note': note,
  };

  /// Wire form sent to the server: no prices at all.
  Json toApi() => {
    'id': lineId,
    'productId': productId,
    'quantity': quantity,
    if (notes != null) 'notes': notes,
  };
}

class OrderDraft {
  const OrderDraft({
    required this.id,
    required this.facilityId,
    required this.lines,
    this.tabId,
    this.tableId,
    this.tableName,
    this.customerName,
    this.createdAt,
  });

  factory OrderDraft.fromJson(Json j) => OrderDraft(
    id: j.str('id'),
    facilityId: j.str('facilityId'),
    tabId: j.strOrNull('tabId'),
    tableId: j.strOrNull('tableId'),
    tableName: j.strOrNull('tableName'),
    customerName: j.strOrNull('customerName'),
    lines: j.list('lines').map(DraftLine.fromJson).toList(),
    createdAt: j.date('createdAt'),
  );

  final String id;
  final String facilityId;
  final String? tabId;
  final String? tableId;
  final String? tableName;
  final String? customerName;
  final List<DraftLine> lines;
  final DateTime? createdAt;

  OrderDraft copyWith({String? tabId, DateTime? createdAt}) => OrderDraft(
    id: id,
    facilityId: facilityId,
    lines: lines,
    tabId: tabId ?? this.tabId,
    tableId: tableId,
    tableName: tableName,
    customerName: customerName,
    createdAt: createdAt ?? this.createdAt,
  );

  Json toJson() => {
    'id': id,
    'facilityId': facilityId,
    'tabId': tabId,
    'tableId': tableId,
    'tableName': tableName,
    'customerName': customerName,
    'createdAt': createdAt?.toIso8601String(),
    'lines': [for (final l in lines) l.toJson()],
  };

  /// `POST /orders` body (CreateOrderRequest).
  Json toApi() => {
    'id': id,
    if (createdAt != null)
      'clientCreatedAt': createdAt!.toUtc().toIso8601String(),
    'facilityId': facilityId,
    if (tableId != null) 'tableId': tableId,
    if (tabId != null) 'tabId': tabId,
    'channel': 'DINE_IN',
    if (customerName != null && customerName!.isNotEmpty)
      'customerName': customerName,
    'lines': [for (final l in lines) l.toApi()],
  };

  /// Best-effort display order shown while pending server confirmation.
  Order toPendingOrder() => Order(
    id: id,
    status: OrderStatus.draft,
    facilityId: facilityId,
    tabId: tabId,
    tableId: tableId,
    tableLabel: tableName,
    customerName: customerName,
    createdAt: createdAt,
    pendingConfirmation: true,
    lines: [
      for (final l in lines)
        OrderLine(
          id: l.lineId,
          productId: l.productId,
          name: l.name,
          quantity: l.quantity,
          notes: l.notes,
        ),
    ],
  );
}

// ------------------------------------------------------------ realtime

class RealtimeEvent {
  const RealtimeEvent(this.name, this.data, {this.eventId});

  /// `order.updated`, `order.ready`, `table.updated`, `approval.requested`,
  /// `approval.decided`, `device.command`, `bill.printed`, `payment.collected`,
  /// `payment.confirmed`, `payment.rejected`, plus synthetic
  /// `realtime.connected`.
  final String name;
  final Json data;
  final String? eventId;
}

// ------------------------------------------------------------ interface

/// The single seam between UI/repositories and the backend. Implemented by
/// [HttpR007Api] (real server) and `MockR007Api` (built-in demo server), so the
/// exact same UI runs against either.
///
/// Every mutating method takes the [idempotencyKey] generated by the caller
/// (so a queued replay re-sends the SAME key).
abstract class R007Api {
  String get baseUrl;

  /// Bearer/device state set by the app after login/enrolment.
  void setDeviceToken(String? token);
  void setSession(
    AuthSession? session, {
    void Function(AuthSession)? onRefreshed,
  });

  Future<SystemInfo> systemInfo();

  Future<DeviceIdentity> registerDevice({
    required String name,
    required String kind,
    required String hardwareId,
    required String registrationCode,
    String? mode,
    required String idempotencyKey,
  });
  Future<DeviceIdentity> getDevice(String deviceId);
  Future<Facility> getFacility(String facilityId);

  Future<AuthSession> loginStaff({
    String? identifier,
    required String secret,
    required String credentialType,
  });
  Future<void> logout();

  /// Supervisor re-authentication; returns a single-use step-up token.
  Future<StepUp> stepUp({
    String? identifier,
    required String secret,
    required String credentialType,
    required String permission,
    String? entityType,
    String? entityId,
  });

  Future<List<Facility>> listFacilities();
  Future<FacilityRules> getRules(String facilityId);
  Future<Checkout> checkoutDevice({
    required String deviceId,
    required String staffId,
    required String facilityId,
    String? shiftId,
    required String idempotencyKey,
  });
  Future<void> checkinDevice({
    required String deviceId,
    required String idempotencyKey,
  });

  Future<Catalog> getCatalog(String facilityId);
  Future<List<TableInfo>> listTables(String facilityId);
  Future<void> openTable(String tableId, {required String idempotencyKey});
  Future<TabInfo> openTab({
    required String id,
    required String facilityId,
    String? tableId,
    String? customerName,
    required String idempotencyKey,
  });
  Future<List<TabInfo>> listTabs(String facilityId);

  Future<Order> createOrder(OrderDraft draft, {required String idempotencyKey});
  Future<Order> sendOrder(String orderId, {required String idempotencyKey});

  /// Edits a DRAFT order that was created but could not be sent (e.g. the
  /// server refused: insufficient stock), so a retry never re-creates it.
  Future<Order> addOrderLine(
    String orderId,
    DraftLine line, {
    required String idempotencyKey,
  });
  Future<Order> removeOrderLine(String orderId, String lineId);
  Future<Order> getOrder(String orderId);

  /// Open orders of a facility, WITH lines.
  Future<List<Order>> listOrders(String facilityId);
  Future<Order> markServed(String orderId, {required String idempotencyKey});

  Future<SensitiveResult> voidOrder(
    String orderId, {
    required String reason,
    String? stepUpToken,
    required String idempotencyKey,
  });
  Future<SensitiveResult> adjustLine(
    String orderId,
    String lineId, {
    required String
    kind, // DISCOUNT_PERCENT | DISCOUNT_AMOUNT | PRICE_OVERRIDE | COMP
    String? value,
    required String reason,
    String? stepUpToken,
    required String idempotencyKey,
  });

  /// [scope]: `approvable` (supervisor queue) or `mine` (requester).
  Future<List<Approval>> listApprovals({
    required String scope,
    String? status,
    String? facilityId,
  });
  Future<Approval> decideApproval(
    String approvalId, {
    required bool approve,
    String? note,
    String? stepUpToken,
    required String idempotencyKey,
  });

  Future<RedeemResult> redeem({
    required String qrToken,
    required String facilityId,
    required String idempotencyKey,
  });
  Future<Entitlement> getEntitlementByToken(String qrToken);
  Future<Entitlement> releaseItems(
    String entitlementId, {
    required List<String> itemIds,
    String? note,
    required String idempotencyKey,
  });
  Future<Entitlement> returnItems(
    String entitlementId, {
    required List<String> itemIds,
    String condition = 'OK',
    String? note,
    required String idempotencyKey,
  });

  // ------------------------------------------------- waiter collection

  /// `POST /orders/{id}/bill` - pre-bill request (`bill.print`). Idempotent.
  Future<Order> printBill(String orderId, {required String idempotencyKey});

  /// `POST /orders/{id}/collections` (a wire `Payment`). The waiter records / initiates a tender;
  /// the result is never "paid": it is PENDING_CONFIRMATION (or
  /// AWAITING_PAYMENT for a pay link / transfer account). Idempotent by
  /// [CollectionRequest.id] and [idempotencyKey].
  Future<Collection> createCollection(
    CollectionRequest request, {
    required String idempotencyKey,
  });

  /// `GET /payments/paystack/verify/{reference}`: asks the server to check
  /// a pay link / transfer with the provider now (the polling fallback, for a
  /// local node that cannot receive the provider webhook). Best effort.
  Future<void> verifyProviderPayment(String reference);

  /// Collections of an order (`GET /payments?orderId=`); statuses are live
  /// server truth.
  Future<List<Collection>> listCollections(String orderId);

  /// This waiter's collections since [since] (`GET /payments?collectedBy=`).
  Future<List<Collection>> listMyCollections(
    String staffId, {
    required DateTime since,
  });

  /// This waiter's recent cash handovers (`GET /cash-handovers?waiterId=`).
  Future<List<CashHandover>> listHandovers(String staffId);

  /// `GET /staff/{id}/collection-policy` (effective, facility/staff).
  Future<CollectionPolicy> collectionPolicy(
    String staffId, {
    String? facilityId,
  });

  /// `GET /staff/{id}/cash-in-hand`.
  Future<CashInHand> cashInHand(String staffId);

  /// `POST /cash-handovers` - the waiter declares the cash handed to the
  /// cashier; the server returns expected amount + variance.
  Future<CashHandover> createHandover({
    required String id,
    required String declaredAmount,
    String? note,
    required String idempotencyKey,
  });

  /// Live events (Reverb/Pusher for the real API, simulated for the mock).
  Stream<RealtimeEvent> realtime({
    required String facilityId,
    required String deviceId,
  });

  void close();
}
