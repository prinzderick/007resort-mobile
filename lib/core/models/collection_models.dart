import '../util/json.dart';
import '../util/money.dart';

/// Waiter-side payment collection models.
///
/// Business rule (owner): the cashier prints the bill; the waiter collects
/// (cash / card machine / transfer / pay link) but can NEVER mark a bill paid.
/// Waiter-collected money is PENDING until the cashier verifies it, or is
/// confirmed automatically when the provider (Paystack / per-bill transfer
/// account) confirms. All money here is a server decimal STRING; the client
/// only displays it.

abstract final class TenderMethod {
  static const cash = 'CASH';
  static const cardTerminal = 'CARD_TERMINAL';
  static const transfer = 'TRANSFER';
  static const payLink = 'PAY_LINK';

  static const all = [cash, cardTerminal, transfer, payLink];

  /// Methods that require the server (a provider round trip) to start.
  static bool needsNetwork(String m) => m == transfer || m == payLink;

  /// Records the waiter makes by hand: safe to queue while offline.
  static bool queueable(String m) => m == cash || m == cardTerminal;

  static String label(String m) => switch (m) {
    cash => 'Cash',
    cardTerminal => 'Card machine',
    transfer => 'Transfer',
    payLink => 'Pay link',
    _ => m,
  };
}

abstract final class CollectionStatus {
  static const pendingConfirmation = 'PENDING_CONFIRMATION';

  /// Pay link / per-bill transfer account created; nothing paid yet.
  static const awaitingPayment = 'AWAITING_PAYMENT';

  /// Reserved for a future integrated card terminal ("Waiting for machine").
  /// Today's manual bank-POS flow never produces it.
  static const awaitingTerminal = 'AWAITING_TERMINAL';
  static const confirmed = 'CONFIRMED';
  static const rejected = 'REJECTED';
  static const expired = 'EXPIRED';
  static const cancelled = 'CANCELLED';

  /// Local only: queued on the tablet, not yet accepted by the server.
  static const pendingSync = 'PENDING_SYNC';

  static String label(String s) => switch (s) {
    pendingConfirmation => 'Pending cashier confirmation',
    awaitingPayment => 'Waiting for payment',
    awaitingTerminal => 'Waiting for machine...',
    confirmed => 'Confirmed',
    rejected => 'Rejected',
    expired => 'Expired',
    cancelled => 'Cancelled',
    pendingSync => 'Pending sync',
    _ => s.replaceAll('_', ' '),
  };
}

/// Bill state of an order (server-computed).
class BillInfo {
  const BillInfo({
    this.status = 'OPEN',
    this.printedAt,
    this.printedByName,
    this.total,
    this.confirmed,
    this.pending,
    this.remaining,
  });

  /// Wire fields of Order / OrderSummary (WAITER_COLLECTION.md section 1):
  /// `billState` OPEN|BILL_PRINTED, `billPrintedAt`, `amountPaid` (captured),
  /// `pendingCollected`, `collectable` (= total - captured - pending).
  factory BillInfo.fromOrderJson(Json o) {
    final state = o.str('billState', 'OPEN');
    return BillInfo(
      status: state == 'BILL_PRINTED' || state == 'PRINTED'
          ? 'PRINTED'
          : 'OPEN',
      printedAt: o.date('billPrintedAt'),
      total: o.strOrNull('total'),
      confirmed: o.strOrNull('amountPaid'),
      pending: o.strOrNull('pendingCollected'),
      remaining: o.strOrNull('collectable'),
    );
  }

  factory BillInfo.fromJson(Json j) => BillInfo(
    status: j.str('status', 'OPEN'),
    printedAt: j.date('printedAt'),
    printedByName: j.strOrNull('printedByName'),
    total: j.strOrNull('total'),
    confirmed: j.strOrNull('confirmed'),
    pending: j.strOrNull('pending'),
    remaining: j.strOrNull('remaining'),
  );

  Json toJson() => {
    'status': status,
    'printedAt': printedAt?.toIso8601String(),
    'printedByName': printedByName,
    'total': total,
    'confirmed': confirmed,
    'pending': pending,
    'remaining': remaining,
  };

  /// `OPEN` (not printed) or `PRINTED`.
  final String status;
  final DateTime? printedAt;
  final String? printedByName;
  final String? total;

  /// Money the cashier / provider has confirmed.
  final String? confirmed;

  /// Waiter-collected money awaiting cashier verification.
  final String? pending;

  /// Still to be collected: total - confirmed - pending (server-computed).
  final String? remaining;

  bool get printed => status == 'PRINTED';

  /// What is still to be collected once the records saved on THIS tablet
  /// (pending sync, unknown to the server) are counted, so a waiter cannot
  /// enter the same money twice while offline. Display only: the server
  /// re-checks everything when the records sync.
  String? remainingAfter(Iterable<Collection> unsynced) {
    final r = remaining;
    if (r == null) return null;
    var minor = Money.toMinor(r);
    for (final c in unsynced) {
      minor -= Money.toMinor(c.amount);
    }
    return Money.fromMinor(minor.isNegative ? BigInt.zero : minor);
  }
}

/// One tender collected (or being collected) by a waiter.
class Collection {
  const Collection({
    required this.id,
    required this.method,
    required this.amount,
    required this.status,
    this.orderId,
    this.tendered,
    this.changeGiven,
    this.approvalCode,
    this.cardLast4,
    this.slipReference,
    this.bankReference,
    this.rejectionReason,
    this.collectedAt,
    this.collectedByName,
    this.payLinkUrl,
    this.shortLink,
    this.transferBank,
    this.transferAccountNumber,
    this.transferAccountName,
    this.expiresAt,
    this.orderNumber,
    this.providerReference,
  });

  /// Wire `Payment` (with its `collection` block) -> Collection.
  /// Ledger status mapping: AUTHORIZING = waiting for the provider,
  /// CAPTURED = confirmed; FAILED is shown as rejected.
  factory Collection.fromPayment(
    Json p, {
    Json? payLink,
    Json? transferAccount,
    String? orderId,
  }) {
    final col = p.obj('collection');
    final link = payLink ?? const <String, dynamic>{};
    final xfer = transferAccount ?? const <String, dynamic>{};
    final alloc = p.list('allocations');
    final raw = p.str('status');
    final status = switch (raw) {
      'AUTHORIZING' || 'INITIATED' => CollectionStatus.awaitingPayment,
      'CAPTURED' ||
      'PARTIALLY_REFUNDED' ||
      'REFUNDED' => CollectionStatus.confirmed,
      'FAILED' || 'REJECTED' => CollectionStatus.rejected,
      _ => raw.isEmpty ? CollectionStatus.pendingConfirmation : raw,
    };
    return Collection(
      id: p.str('id'),
      orderId:
          orderId ?? (alloc.isEmpty ? null : alloc.first.strOrNull('orderId')),
      orderNumber: p.strOrNull('orderNumber'),
      method: col.str('tender', TenderMethod.cash),
      amount: p.str('amount', '0.00'),
      status: status,
      tendered: p.strOrNull('tendered'),
      changeGiven: p.strOrNull('changeGiven'),
      approvalCode: col.strOrNull('approvalCode'),
      cardLast4: col.strOrNull('last4'),
      slipReference: col.strOrNull('slipReference'),
      bankReference: col.strOrNull('bankReference'),
      rejectionReason: col.strOrNull('decisionReason'),
      collectedAt: p.date('createdAt') ?? col.date('clientCreatedAt'),
      collectedByName: null,
      payLinkUrl: link.strOrNull('authorizationUrl'),
      providerReference:
          link.strOrNull('reference') ??
          p.strOrNull('providerReference') ??
          p.strOrNull('reference'),
      transferBank: xfer.strOrNull('bankName'),
      transferAccountNumber: xfer.strOrNull('accountNumber'),
      transferAccountName: xfer.strOrNull('accountName'),
      expiresAt: xfer.date('expiresAt') ?? col.date('expiresAt'),
    );
  }

  /// Keeps this collection's link / account details (which the server only
  /// returns when the collection is created) while adopting a fresher status.
  Collection withLiveState(Collection live) => Collection(
    id: id,
    orderId: live.orderId ?? orderId,
    orderNumber: live.orderNumber ?? orderNumber,
    method: method,
    amount: live.amount,
    status: live.status,
    tendered: live.tendered ?? tendered,
    changeGiven: live.changeGiven ?? changeGiven,
    approvalCode: live.approvalCode ?? approvalCode,
    cardLast4: live.cardLast4 ?? cardLast4,
    slipReference: live.slipReference ?? slipReference,
    bankReference: live.bankReference ?? bankReference,
    rejectionReason: live.rejectionReason ?? rejectionReason,
    collectedAt: collectedAt ?? live.collectedAt,
    payLinkUrl: payLinkUrl ?? live.payLinkUrl,
    shortLink: shortLink ?? live.shortLink,
    transferBank: transferBank ?? live.transferBank,
    transferAccountNumber: transferAccountNumber ?? live.transferAccountNumber,
    transferAccountName: transferAccountName ?? live.transferAccountName,
    expiresAt: expiresAt ?? live.expiresAt,
    providerReference: providerReference ?? live.providerReference,
  );

  final String id;
  final String? orderId;
  final String? orderNumber;
  final String method;
  final String amount;
  final String status;
  final String? tendered;
  final String? changeGiven;
  final String? approvalCode;
  final String? cardLast4;
  final String? slipReference;
  final String? bankReference;
  final String? rejectionReason;
  final DateTime? collectedAt;
  final String? collectedByName;
  final String? payLinkUrl;
  final String? shortLink;
  final String? transferBank;
  final String? transferAccountNumber;
  final String? transferAccountName;
  final DateTime? expiresAt;

  /// Provider (Paystack) reference of a pay link / transfer account; used to
  /// ask the server to verify it when no webhook can reach the local node.
  final String? providerReference;

  bool get isConfirmed => status == CollectionStatus.confirmed;
  bool get isRejected => status == CollectionStatus.rejected;
  bool get isWaiting =>
      status == CollectionStatus.awaitingPayment ||
      status == CollectionStatus.awaitingTerminal;
  bool get isTerminalFailure =>
      status == CollectionStatus.rejected ||
      status == CollectionStatus.expired ||
      status == CollectionStatus.cancelled;

  /// What the customer scans / opens: the pay link, when there is one.
  String? get qrData => payLinkUrl ?? shortLink;
}

/// Request body of `POST /orders/{id}/collections`. [id] is a client UUIDv7
/// so a replay (offline queue, double tap, retry) returns the original.
class CollectionRequest {
  const CollectionRequest({
    required this.id,
    required this.orderId,
    required this.method,
    required this.amount,
    this.tendered,
    this.approvalCode,
    this.cardLast4,
    this.slipReference,
    this.bankReference,
    this.note,
    this.orderNumber,
    this.collectedAt,
    this.terminalId,
    this.customerEmail,
  });

  factory CollectionRequest.fromJson(Json j) => CollectionRequest(
    id: j.str('id'),
    orderId: j.str('orderId'),
    orderNumber: j.strOrNull('orderNumber'),
    method: j.str('method'),
    amount: j.str('amount'),
    tendered: j.strOrNull('tendered'),
    approvalCode: j.strOrNull('approvalCode'),
    cardLast4: j.strOrNull('cardLast4'),
    slipReference: j.strOrNull('slipReference'),
    bankReference: j.strOrNull('bankReference'),
    note: j.strOrNull('note'),
    collectedAt: j.date('collectedAt'),
    terminalId: j.strOrNull('terminalId'),
    customerEmail: j.strOrNull('customerEmail'),
  );

  final String id;
  final String orderId;
  final String? orderNumber;
  final String method;
  final String amount;
  final String? tendered;
  final String? approvalCode;
  final String? cardLast4;
  final String? slipReference;
  final String? bankReference;
  final String? note;

  /// Future integrated terminal (optional; unused for the manual bank POS).
  final String? terminalId;

  /// PAY_LINK / Paystack transfer (server falls back to a default).
  final String? customerEmail;

  /// When the waiter actually took the money (matters for queued records).
  final DateTime? collectedAt;

  /// Persisted (queue) form.
  Json toJson() => {
    'id': id,
    'orderId': orderId,
    'orderNumber': orderNumber,
    'method': method,
    'amount': amount,
    'tendered': tendered,
    'approvalCode': approvalCode,
    'cardLast4': cardLast4,
    'slipReference': slipReference,
    'bankReference': bankReference,
    'note': note,
    'collectedAt': collectedAt?.toUtc().toIso8601String(),
    'terminalId': terminalId,
    'customerEmail': customerEmail,
  };

  /// Wire form (`CollectionRequest`). TRANSFER with a bank reference is a
  /// MANUAL record for the cashier to verify; without one it asks for the
  /// bill's own Paystack account (auto-confirmed).
  Json toApi() => {
    'id': id,
    'tenderType': method,
    'amount': amount,
    if (tendered != null && tendered!.isNotEmpty) 'tendered': tendered,
    if (approvalCode != null && approvalCode!.isNotEmpty)
      'approvalCode': approvalCode,
    if (cardLast4 != null && cardLast4!.isNotEmpty) 'last4': cardLast4,
    if (slipReference != null && slipReference!.isNotEmpty)
      'slipReference': slipReference,
    if (bankReference != null && bankReference!.isNotEmpty)
      'bankReference': bankReference,
    if (method == TenderMethod.transfer)
      'channel': (bankReference ?? '').isNotEmpty ? 'MANUAL' : 'PAYSTACK',
    if (customerEmail != null && customerEmail!.isNotEmpty)
      'customerEmail': customerEmail,
    if (note != null && note!.isNotEmpty) 'note': note,
    if (terminalId != null && terminalId!.isNotEmpty) 'terminalId': terminalId,
    if (collectedAt != null)
      'clientCreatedAt': collectedAt!.toUtc().toIso8601String(),
  };

  /// Display copy of a record queued offline (never confirmed by the server).
  Collection toPendingSync() => Collection(
    id: id,
    orderId: orderId,
    orderNumber: orderNumber,
    method: method,
    amount: amount,
    status: CollectionStatus.pendingSync,
    tendered: tendered,
    approvalCode: approvalCode,
    cardLast4: cardLast4,
    slipReference: slipReference,
    collectedAt: collectedAt,
  );
}

/// `GET /staff/{id}/cash-in-hand`.
class CashInHand {
  const CashInHand({
    this.cashInHand = '0.00',
    this.currency = 'NGN',
    this.limit,
    this.handoverRequired = false,
    this.cashHoldingAllowed = true,
    this.pendingCollections = 0,
    this.pendingCollectionsAmount,
    this.openHandovers = 0,
    this.unsignedShortfall,
    this.oldestUncollectedAt,
  });

  factory CashInHand.fromJson(Json j) => CashInHand(
    cashInHand: j.str('cashInHand', '0.00'),
    currency: j.str('currency', 'NGN'),
    limit: j.strOrNull('limit'),
    handoverRequired: j.boolOr('handoverRequired'),
    cashHoldingAllowed: j['cashHoldingAllowed'] is bool
        ? j['cashHoldingAllowed'] as bool
        : true,
    pendingCollections: j.intOr('pendingCollections'),
    pendingCollectionsAmount: j.strOrNull('pendingCollectionsAmount'),
    openHandovers: j.intOr('openHandovers'),
    unsignedShortfall: j.strOrNull('unsignedShortfall'),
    oldestUncollectedAt: j.date('oldestUncollectedAt'),
  );

  final String cashInHand;
  final String currency;

  /// Effective cash-holding limit (server policy); null = none.
  final String? limit;

  /// The server says a handover is due (limit reached).
  final bool handoverRequired;
  final bool cashHoldingAllowed;
  final int pendingCollections;
  final String? pendingCollectionsAmount;
  final int openHandovers;
  final String? unsignedShortfall;
  final DateTime? oldestUncollectedAt;
}

abstract final class HandoverStatus {
  static const pendingReceipt = 'PENDING_RECEIPT';
  static const received = 'RECEIVED';
  static const pendingSignoff = 'PENDING_SIGNOFF';
  static const signedOff = 'SIGNED_OFF';
}

/// `POST /cash-handovers` result. The waiter DECLARES; the cashier later
/// counts it and the server records `variance = counted - declared`.
class CashHandover {
  const CashHandover({
    required this.id,
    required this.declaredAmount,
    this.expectedInHand,
    this.countedAmount,
    this.variance,
    this.varianceKind,
    this.requiresSignoff = false,
    this.status = HandoverStatus.pendingReceipt,
    this.createdAt,
    this.receivedAt,
  });

  factory CashHandover.fromJson(Json j) => CashHandover(
    id: j.str('id'),
    declaredAmount: j.str('declaredAmount', '0.00'),
    expectedInHand: j.strOrNull('expectedInHand'),
    countedAmount: j.strOrNull('countedAmount'),
    variance: j.strOrNull('variance'),
    varianceKind: j.strOrNull('varianceKind'),
    requiresSignoff: j.boolOr('requiresSignoff'),
    status: j.str('status', HandoverStatus.pendingReceipt),
    createdAt: j.date('createdAt'),
    receivedAt: j.date('receivedAt'),
  );

  final String id;
  final String declaredAmount;

  /// What the server had recorded as cash in hand when this was declared.
  final String? expectedInHand;
  final String? countedAmount;

  /// counted - declared (server-computed; negative = short). Null until the
  /// cashier has counted it.
  final String? variance;

  /// EXACT | OVER | SHORT
  final String? varianceKind;
  final bool requiresSignoff;
  final String status;
  final DateTime? createdAt;
  final DateTime? receivedAt;

  bool get isWaiting => status == HandoverStatus.pendingReceipt;
}

/// `GET /staff/{id}/collection-policy`: the EFFECTIVE policy for this waiter
/// (facility rule, overridden per staff). The server enforces it; the UI only
/// mirrors it so staff are not offered what will be refused.
class CollectionPolicy {
  const CollectionPolicy({
    this.source = 'facility',
    this.collectionEnabled = true,
    this.cashHoldingAllowed = true,
    this.cashLimit,
    this.allowedTenders = TenderMethod.all,
  });

  factory CollectionPolicy.fromJson(Json j) {
    final h = j.obj('cashHolding');
    return CollectionPolicy(
      source: h.str('source', 'facility'),
      collectionEnabled: j['collectionEnabled'] is bool
          ? j['collectionEnabled'] as bool
          : true,
      cashHoldingAllowed: h['allowed'] is bool ? h['allowed'] as bool : true,
      cashLimit: h.strOrNull('limit'),
      allowedTenders: j['allowedTenders'] is List
          ? [for (final t in j['allowedTenders'] as List) t.toString()]
          : TenderMethod.all,
    );
  }

  Json toJson() => {
    'collectionEnabled': collectionEnabled,
    'cashHolding': {
      'allowed': cashHoldingAllowed,
      'source': source,
      'limit': cashLimit,
    },
    'allowedTenders': allowedTenders,
  };

  /// Used until the server answers (the server still enforces everything).
  static const permissive = CollectionPolicy();

  final String source; // facility | staff
  final bool collectionEnabled;
  final bool cashHoldingAllowed;

  /// Max cash a waiter may hold before handing over (null = unlimited).
  final String? cashLimit;
  final List<String> allowedTenders;

  /// The tender is offered at all (allowed by policy).
  bool allows(String method) {
    if (!allowedTenders.contains(method)) return false;
    if (method == TenderMethod.cash && !cashHoldingAllowed) return false;
    return true;
  }
}
