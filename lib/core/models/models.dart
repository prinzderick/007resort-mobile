import '../device/device_mode.dart';
import '../util/json.dart';

/// Wire-format domain models (contract: 007resort-docs api/openapi/v1.yaml).
/// All money values are decimal STRINGS exactly as sent by the server; the
/// client never does authoritative arithmetic. Unknown fields/enum values are
/// tolerated (contract rule: "ignore unknown fields").

class Staff {
  const Staff({
    required this.id,
    required this.name,
    this.staffNumber = '',
    this.permissions = const {},
    this.facilityIds = const [],
  });

  factory Staff.fromJson(Json j) => Staff(
    id: j.str('id'),
    name: j.str('displayName', j.str('name')),
    staffNumber: j.str('staffNumber'),
    permissions: {
      for (final p in (j['permissions'] as List? ?? const [])) p.toString(),
    },
    facilityIds: [
      for (final p in (j['facilityIds'] as List? ?? const [])) p.toString(),
    ],
  );

  Json toJson() => {
    'id': id,
    'displayName': name,
    'staffNumber': staffNumber,
    'permissions': permissions.toList(),
    'facilityIds': facilityIds,
  };

  final String id;
  final String name;
  final String staffNumber;
  final Set<String> permissions;
  final List<String> facilityIds;

  /// UI gating only - the server still enforces every permission.
  bool can(String permission) => permissions.contains(permission);
}

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.staff,
    this.sessionId,
  });

  factory AuthSession.fromJson(Json j, {DateTime? now}) => AuthSession(
    accessToken: j.str('accessToken'),
    refreshToken: j.str('refreshToken'),
    expiresAt: (now ?? DateTime.now().toUtc()).add(
      Duration(seconds: j.intOr('expiresInSeconds', 900)),
    ),
    staff: Staff.fromJson(j.obj('staff')),
    sessionId: j.obj('session').strOrNull('id'),
  );

  factory AuthSession.fromStored(Json j) => AuthSession(
    accessToken: j.str('accessToken'),
    refreshToken: j.str('refreshToken'),
    expiresAt: j.date('expiresAt') ?? DateTime.now().toUtc(),
    staff: Staff.fromJson(j.obj('staff')),
    sessionId: j.strOrNull('sessionId'),
  );

  Json toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toIso8601String(),
    'staff': staff.toJson(),
    'sessionId': sessionId,
  };

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final Staff staff;
  final String? sessionId;
}

class StepUp {
  const StepUp({required this.token, this.approverName});
  final String token;
  final String? approverName;
}

class RealtimeInfo {
  const RealtimeInfo({
    required this.scheme,
    required this.host,
    required this.port,
    required this.appKey,
  });
  factory RealtimeInfo.fromJson(Json j) => RealtimeInfo(
    scheme: j.str('scheme', 'ws'),
    host: j.str('host'),
    port: j.intOr('port', 8081),
    appKey: j.str('appKey'),
  );
  final String scheme;
  final String host;
  final int port;
  final String appKey;
}

class SystemInfo {
  const SystemInfo({
    this.service = '',
    this.apiVersion = '',
    this.deploymentMode = '',
    this.minMobileVersion,
    this.realtime,
  });
  factory SystemInfo.fromJson(Json j) => SystemInfo(
    service: j.str('service'),
    apiVersion: j.str('apiVersion'),
    deploymentMode: j.str('deploymentMode'),
    minMobileVersion: j.obj('minClientVersion').strOrNull('mobile'),
    realtime: j['realtime'] is Map<String, dynamic>
        ? RealtimeInfo.fromJson(j.obj('realtime'))
        : null,
  );
  final String service;
  final String apiVersion;
  final String deploymentMode;
  final String? minMobileVersion;
  final RealtimeInfo? realtime;
}

class Facility {
  const Facility({
    required this.id,
    required this.name,
    this.kind = '',
    this.code = '',
  });
  factory Facility.fromJson(Json j) => Facility(
    id: j.str('id'),
    name: j.str('name'),
    kind: j.str('kind'),
    code: j.str('code'),
  );
  final String id;
  final String name;

  /// RESTAURANT, BAR, SPORTS_STORE, SPORTS_ENTRANCE, POOL, RECEPTION, ...
  final String kind;
  final String code;
}

class FacilityRules {
  const FacilityRules({
    this.allowOpenTabs = true,
    this.allowOfflineOrders = true,
  });
  factory FacilityRules.fromJson(Json j) {
    final r = j.obj('operatingRules');
    return FacilityRules(
      allowOpenTabs: r['allowOpenTabs'] is bool
          ? r['allowOpenTabs'] as bool
          : true,
      allowOfflineOrders: r['allowOfflineOrders'] is bool
          ? r['allowOfflineOrders'] as bool
          : true,
    );
  }
  final bool allowOpenTabs;
  final bool allowOfflineOrders;
}

/// Result of device enrolment / lookup (contract `Device` + `deviceToken`).
///
/// The UI persona comes from the server's explicit `mode` field (never
/// inferred from the home facility). `homeFacility {id, code, name, kind}` is
/// a summary embedded in the device so no protected lookup is needed before
/// staff sign in.
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.deviceToken,
    this.kind = 'MOBILE_TABLET',
    this.name = '',
    this.modeValue,
    this.homeFacilityId,
    this.homeFacilityKind,
    this.homeFacilityCode,
    this.homeFacilityName,
    this.checkoutStaffId,
    this.checkoutFacilityId,
  });

  factory DeviceIdentity.fromJson(Json j, {String? token}) {
    final home = j.obj('homeFacility');
    return DeviceIdentity(
      deviceId: j.str('id', j.str('deviceId')),
      deviceToken: token ?? j.str('deviceToken'),
      kind: j.str('kind', 'MOBILE_TABLET'),
      name: j.str('name'),
      modeValue: j.strOrNull('mode'),
      homeFacilityId: home.strOrNull('id') ?? j.strOrNull('homeFacilityId'),
      homeFacilityKind:
          home.strOrNull('kind') ?? j.strOrNull('homeFacilityKind'),
      homeFacilityCode:
          home.strOrNull('code') ?? j.strOrNull('homeFacilityCode'),
      homeFacilityName:
          home.strOrNull('name') ?? j.strOrNull('homeFacilityName'),
      checkoutStaffId: j.obj('checkout').strOrNull('staffId'),
      checkoutFacilityId: j.obj('checkout').strOrNull('facilityId'),
    );
  }

  /// Persisted form (same shape as the API, so it round-trips `fromJson`).
  Json toJson() => {
    'id': deviceId,
    'deviceToken': deviceToken,
    'kind': kind,
    'name': name,
    'mode': modeValue,
    'homeFacilityId': homeFacilityId,
    'homeFacilityKind': homeFacilityKind,
    'homeFacilityCode': homeFacilityCode,
    'homeFacilityName': homeFacilityName,
  };

  final String deviceId;
  final String deviceToken;
  final String kind;
  final String name;

  /// Raw `mode` sent by the server (ATTENDANT, SUPERVISOR, ...).
  final String? modeValue;
  final String? homeFacilityId;
  final String? homeFacilityKind;
  final String? homeFacilityCode;
  final String? homeFacilityName;
  final String? checkoutStaffId;
  final String? checkoutFacilityId;

  /// The persona from the server's explicit `mode`. Only when an older server
  /// omits it is the documented server default for the device kind used
  /// (MOBILE_TABLET -> ATTENDANT, ENTRANCE_SCANNER -> SPORTS_ENTRANCE).
  /// Unknown values never unlock a UI.
  DeviceMode get mode {
    if (modeValue != null && modeValue!.isNotEmpty) {
      return DeviceMode.fromApi(modeValue);
    }
    return switch (kind) {
      'MOBILE_TABLET' => DeviceMode.attendant,
      'ENTRANCE_SCANNER' => DeviceMode.sportsEntrance,
      _ => DeviceMode.unregistered,
    };
  }
}

class Checkout {
  const Checkout({
    required this.facility,
    this.shiftId,
    this.staffId,
    this.checkedOutAt,
  });
  factory Checkout.fromJson(Json j) => Checkout(
    facility: Facility.fromJson(j.obj('facility')),
    shiftId: j.strOrNull('shiftId'),
    staffId: j.strOrNull('staffId'),
    checkedOutAt: j.date('checkedOutAt'),
  );
  Json toJson() => {
    'facility': {
      'id': facility.id,
      'name': facility.name,
      'kind': facility.kind,
      'code': facility.code,
    },
    'shiftId': shiftId,
    'staffId': staffId,
    'checkedOutAt': checkedOutAt?.toIso8601String(),
  };
  final Facility facility;
  final String? shiftId;
  final String? staffId;
  final DateTime? checkedOutAt;
}

// ---------------------------------------------------------------- catalog

class ModifierOption {
  const ModifierOption({
    required this.id,
    required this.name,
    this.priceDelta = '0.00',
  });
  final String id;
  final String name;
  final String priceDelta;
}

/// Optional (mock/future contract): the v1 contract has no modifier groups, so
/// selections are sent to the server as the order line `notes` text.
class ModifierGroup {
  const ModifierGroup({
    required this.id,
    required this.name,
    this.minSelect = 0,
    this.maxSelect = 1,
    this.options = const [],
  });
  final String id;
  final String name;
  final int minSelect;
  final int maxSelect;
  final List<ModifierOption> options;
  bool get required => minSelect > 0;
}

class Category {
  const Category({required this.id, required this.name});
  factory Category.fromJson(Json j) =>
      Category(id: j.str('id'), name: j.str('name'));
  Json toJson() => {'id': id, 'name': name};
  final String id;
  final String name;
}

class Product {
  const Product({
    required this.id,
    required this.name,
    required this.categoryId,
    required this.price,
    this.currency = 'NGN',
    this.available = true,
    this.kind = 'FOOD',
    this.prepKind = 'NONE',
    this.modifierGroups = const [],
  });
  factory Product.fromJson(Json j) => Product(
    id: j.str('id'),
    name: j.str('name'),
    categoryId: j.str('categoryId'),
    price: j.str('price', '0.00'),
    currency: j.str('currency', 'NGN'),
    available: j['active'] is bool ? j['active'] as bool : true,
    kind: j.str('kind', 'FOOD'),
    prepKind: j.obj('prepRoute').str('kind', 'NONE'),
  );
  Json toJson() => {
    'id': id,
    'name': name,
    'categoryId': categoryId,
    'price': price,
    'currency': currency,
    'active': available,
    'kind': kind,
    'prepRoute': {'kind': prepKind},
  };
  final String id;
  final String name;
  final String categoryId;
  final String price;
  final String currency;
  final bool available;
  final String kind;
  final String prepKind;
  final List<ModifierGroup> modifierGroups;
}

class Catalog {
  const Catalog({this.categories = const [], this.products = const []});
  factory Catalog.fromJson(Json j) => Catalog(
    categories: j.list('categories').map(Category.fromJson).toList(),
    products: j.list('products').map(Product.fromJson).toList(),
  );
  Json toJson() => {
    'categories': [for (final c in categories) c.toJson()],
    'products': [for (final p in products) p.toJson()],
  };
  final List<Category> categories;
  final List<Product> products;
}

// ----------------------------------------------------------------- orders

abstract final class OrderStatus {
  static const draft = 'DRAFT';
  static const sent = 'SENT';
  static const inPreparation = 'IN_PREPARATION';
  static const ready = 'READY';
  static const served = 'SERVED';
  static const settled = 'SETTLED';
  static const voided = 'VOIDED';
  static const pendingApproval = 'PENDING_APPROVAL';
}

abstract final class LineStatus {
  static const pending = 'PENDING';
  static const locked = 'LOCKED';
  static const routed = 'ROUTED';
  static const accepted = 'ACCEPTED';
  static const inProgress = 'IN_PROGRESS';
  static const ready = 'READY';
  static const dispensed = 'DISPENSED';
  static const voided = 'VOIDED';
  static const removed = 'REMOVED';
}

class OrderLine {
  const OrderLine({
    required this.id,
    required this.productId,
    required this.name,
    required this.quantity,
    this.unitPrice,
    this.lineTotal,
    this.status = LineStatus.pending,
    this.notes,
    this.adjustments = const [],
  });
  factory OrderLine.fromJson(Json j) => OrderLine(
    id: j.str('id'),
    productId: j.str('productId'),
    name: j.str('name'),
    quantity: j.intOr('quantity', 1),
    unitPrice: j.strOrNull('unitPrice'),
    lineTotal: j.strOrNull('lineTotal'),
    status: j.str('status', LineStatus.pending),
    notes: j.strOrNull('notes'),
    adjustments: [
      for (final a in j.list('adjustments'))
        '${a.str('kind')} ${a.str('status')}',
    ],
  );
  final String id;
  final String productId;
  final String name;
  final int quantity;
  final String? unitPrice;
  final String? lineTotal;
  final String status;
  final String? notes;

  /// Human summaries, e.g. "DISCOUNT_PERCENT APPLIED" (display only).
  final List<String> adjustments;
  bool get isReady => status == LineStatus.ready;
  bool get isDone => status == LineStatus.dispensed;
  bool get isVoided =>
      status == LineStatus.voided || status == LineStatus.removed;
}

class Order {
  const Order({
    required this.id,
    required this.status,
    this.facilityId = '',
    this.tabId,
    this.tableId,
    this.tableLabel,
    this.customerName,
    this.lines = const [],
    this.subtotal,
    this.taxTotal,
    this.discountTotal,
    this.total,
    this.balanceDue,
    this.currency = 'NGN',
    this.createdAt,
    this.createdByStaffId,
    this.createdByName,
    this.number,
    this.rowVersion = 0,
    this.pendingApprovalId,
    this.pendingConfirmation = false,
  });
  factory Order.fromJson(Json j) => Order(
    id: j.str('id'),
    status: j.str('status', OrderStatus.draft),
    facilityId: j.str('facilityId'),
    tabId: j.strOrNull('tabId'),
    tableId: j.strOrNull('tableId'),
    tableLabel: j.strOrNull('tableLabel'),
    customerName: j.strOrNull('customerName'),
    lines: j.list('lines').map(OrderLine.fromJson).toList(),
    subtotal: j.strOrNull('subtotal'),
    taxTotal: j.strOrNull('taxTotal'),
    discountTotal: j.strOrNull('discountTotal'),
    total: j.strOrNull('total'),
    balanceDue: j.strOrNull('balanceDue'),
    currency: j.str('currency', 'NGN'),
    createdAt: j.date('createdAt'),
    createdByStaffId: j.strOrNull('createdByStaffId'),
    createdByName: j.strOrNull('createdByName'),
    number: j.strOrNull('number'),
    rowVersion: j.intOr('rowVersion'),
    pendingApprovalId: j.strOrNull('pendingApprovalId'),
  );

  Order copyWith({
    List<OrderLine>? lines,
    String? tableLabel,
    bool? pendingConfirmation,
  }) => Order(
    id: id,
    status: status,
    facilityId: facilityId,
    tabId: tabId,
    tableId: tableId,
    tableLabel: tableLabel ?? this.tableLabel,
    customerName: customerName,
    lines: lines ?? this.lines,
    subtotal: subtotal,
    taxTotal: taxTotal,
    discountTotal: discountTotal,
    total: total,
    balanceDue: balanceDue,
    currency: currency,
    createdAt: createdAt,
    createdByStaffId: createdByStaffId,
    createdByName: createdByName,
    number: number,
    rowVersion: rowVersion,
    pendingApprovalId: pendingApprovalId,
    pendingConfirmation: pendingConfirmation ?? this.pendingConfirmation,
  );

  final String id;
  final String status;
  final String facilityId;
  final String? tabId;
  final String? tableId;
  final String? tableLabel;
  final String? customerName;
  final List<OrderLine> lines;
  final String? subtotal;
  final String? taxTotal;
  final String? discountTotal;
  final String? total;
  final String? balanceDue;
  final String currency;
  final DateTime? createdAt;
  final String? createdByStaffId;
  final String? createdByName;
  final String? number;
  final int rowVersion;
  final String? pendingApprovalId;

  /// Local-only flag: created while offline, not yet confirmed by the server.
  final bool pendingConfirmation;

  bool get isOpen =>
      status != OrderStatus.settled && status != OrderStatus.voided;
  bool get hasReady => lines.any((l) => l.isReady);
  bool get awaitingApproval => status == OrderStatus.pendingApproval;
}

class TableInfo {
  const TableInfo({
    required this.id,
    required this.name,
    this.status = 'FREE',
    this.tabId,
    this.openOrderIds = const [],
  });
  factory TableInfo.fromJson(Json j) => TableInfo(
    id: j.str('id'),
    name: j.str('label', j.str('name')),
    status: j.str('status', 'FREE'),
    tabId: j.strOrNull('openTabId'),
    openOrderIds: [
      for (final o in (j['openOrderIds'] as List? ?? const [])) o.toString(),
    ],
  );
  final String id;
  final String name;

  /// FREE | OCCUPIED | RESERVED | NEEDS_CLEANING
  final String status;
  final String? tabId;
  final List<String> openOrderIds;
  bool get isFree => status == 'FREE';
}

class TabInfo {
  const TabInfo({
    required this.id,
    this.tableId,
    this.customerName,
    this.status = 'OPEN',
    this.orderIds = const [],
    this.total,
    this.balanceDue,
  });
  factory TabInfo.fromJson(Json j) => TabInfo(
    id: j.str('id'),
    tableId: j.strOrNull('tableId'),
    customerName: j.strOrNull('customerName'),
    status: j.str('status', 'OPEN'),
    orderIds: [
      for (final o in (j['orderIds'] as List? ?? const [])) o.toString(),
    ],
    total: j.strOrNull('total'),
    balanceDue: j.strOrNull('balanceDue'),
  );
  final String id;
  final String? tableId;
  final String? customerName;
  final String status;
  final List<String> orderIds;
  final String? total;
  final String? balanceDue;
}

// -------------------------------------------------------------- approvals

class Approval {
  const Approval({
    required this.id,
    required this.action,
    required this.status,
    this.entityType = 'order',
    this.entityId = '',
    this.summary = '',
    this.amount,
    this.reason,
    this.requestedByName,
    this.requestedAt,
    this.decisionNote,
    this.requiredPermission,
  });
  factory Approval.fromJson(Json j) => Approval(
    id: j.str('id'),
    action: j.str('action', 'order.void'),
    status: j.str('status', 'PENDING'),
    entityType: j.str('entityType', 'order'),
    entityId: j.str('entityId'),
    summary: j.str('summary'),
    amount: j.strOrNull('amount'),
    reason: j.strOrNull('reason'),
    requestedByName: j.strOrNull('requestedByName'),
    requestedAt: j.date('requestedAt'),
    decisionNote: j.strOrNull('decisionNote'),
    requiredPermission: j.strOrNull('requiredPermission'),
  );
  final String id;

  /// e.g. `order.void`, `order.discount`, `order.comp`, `order.price_override`.
  final String action;
  final String status;
  final String entityType;
  final String entityId;
  final String summary;
  final String? amount;
  final String? reason;
  final String? requestedByName;
  final DateTime? requestedAt;
  final String? decisionNote;
  final String? requiredPermission;
  bool get isPending => status == 'PENDING';

  String get permission => requiredPermission ?? '$action.approve';

  String get title {
    final a = action.toLowerCase();
    if (a.contains('void')) return 'Void';
    if (a.contains('comp')) return 'Complimentary';
    if (a.contains('discount')) return 'Discount';
    if (a.contains('price')) return 'Price override';
    return action;
  }
}

/// Outcome of a sensitive action: applied immediately (200), or it needs a
/// supervisor decision (202 `ApprovalOutcome`).
class SensitiveResult {
  const SensitiveResult.applied(this.order) : approval = null;
  const SensitiveResult.pending(this.approval, {this.order});
  final Order? order;
  final Approval? approval;
  bool get isPending => approval != null;
}

// ------------------------------------------------------------ entitlements

enum ScanOutcome {
  valid('VALID', 'VALID'),
  used('USED', 'ALREADY USED'),
  expired('EXPIRED', 'EXPIRED'),
  wrongFacility('WRONG_FACILITY', 'WRONG FACILITY'),
  notYetValid('NOT_YET_VALID', 'NOT YET VALID'),
  cancelled('CANCELLED', 'CANCELLED'),
  pending('PENDING', 'STAFF APPROVAL NEEDED'),
  unknown('UNKNOWN', 'NOT RECOGNISED');

  const ScanOutcome(this.wire, this.label);
  final String wire;
  final String label;

  static ScanOutcome fromWire(String? v) {
    final n = (v ?? '').toUpperCase().replaceAll(' ', '_');
    for (final o in values) {
      if (o.wire == n) return o;
    }
    return ScanOutcome.unknown;
  }
}

class EntitlementItem {
  const EntitlementItem({
    required this.id,
    required this.kind,
    required this.name,
    this.quantity = 1,
    this.quantityRedeemed = 0,
    this.rentalStatus,
    this.facilityId,
  });
  factory EntitlementItem.fromJson(Json j) => EntitlementItem(
    id: j.str('id'),
    kind: j.str('kind', 'ITEM'),
    name: j.str('name'),
    quantity: j.intOr('quantity', 1),
    quantityRedeemed: j.intOr('quantityRedeemed'),
    rentalStatus: j.strOrNull('rentalStatus'),
    facilityId: j.strOrNull('facilityId'),
  );

  final String id;

  /// ACCESS | RENTAL | ITEM
  final String kind;
  final String name;
  final int quantity;
  final int quantityRedeemed;

  /// NOT_RELEASED | RELEASED | RETURNED (rentals only)
  final String? rentalStatus;
  final String? facilityId;
  bool get isRental => kind == 'RENTAL';
  bool get isAccess => kind == 'ACCESS';
  bool get isReleased => rentalStatus == 'RELEASED';
  bool get isReturned => rentalStatus == 'RETURNED';

  /// Items the store may hand over. Server truth still decides (409 on repeat).
  bool get canRelease => switch (kind) {
    'RENTAL' => rentalStatus == null || rentalStatus == 'NOT_RELEASED',
    'ITEM' => quantityRedeemed < quantity,
    _ => false,
  };
  bool get canReturn => isRental && isReleased;
}

class Entitlement {
  const Entitlement({
    required this.id,
    required this.status,
    this.qrToken,
    this.holderName,
    this.items = const [],
  });
  factory Entitlement.fromJson(Json j) => Entitlement(
    id: j.str('id'),
    status: j.str('status'),
    qrToken: j.strOrNull('qrToken'),
    holderName: j.strOrNull('holderName'),
    items: j.list('items').map(EntitlementItem.fromJson).toList(),
  );
  final String id;

  /// ACTIVE | CANCELLED | EXHAUSTED | EXPIRED
  final String status;
  final String? qrToken;
  final String? holderName;
  final List<EntitlementItem> items;
  bool get isCancelled => status == 'CANCELLED';
}

class RedeemResult {
  const RedeemResult({
    required this.outcome,
    this.entitlementId,
    this.holderName,
    this.itemName,
    this.message,
    this.remaining,
    this.validFrom,
    this.validUntil,
    this.usedAt,
  });
  factory RedeemResult.fromJson(Json j) => RedeemResult(
    outcome: ScanOutcome.fromWire(j.strOrNull('result')),
    entitlementId: j.strOrNull('entitlementId'),
    holderName: j.strOrNull('holderName'),
    itemName: j.strOrNull('itemName'),
    message: j.strOrNull('message'),
    remaining: j['remaining'] is int ? j['remaining'] as int : null,
    validFrom: j.date('validFrom'),
    validUntil: j.date('validUntil'),
    usedAt: j.date('usedAt'),
  );
  final ScanOutcome outcome;
  final String? entitlementId;
  final String? holderName;
  final String? itemName;
  final String? message;
  final int? remaining;
  final DateTime? validFrom;
  final DateTime? validUntil;
  final DateTime? usedAt;
}

class ScanRecord {
  const ScanRecord({
    required this.code,
    required this.outcome,
    required this.at,
    this.holderName,
    this.itemName,
  });
  final String code;
  final ScanOutcome outcome;
  final DateTime at;
  final String? holderName;
  final String? itemName;
}
