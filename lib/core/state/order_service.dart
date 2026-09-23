import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/r007_api.dart';
import '../models/models.dart';
import '../offline/offline_queue.dart';
import 'app_state.dart';
import 'connectivity.dart';
import 'outbox.dart';

/// Result of submitting an order from the cart.
class SubmitResult {
  const SubmitResult({
    required this.orderId,
    required this.queued,
    this.order,
    this.tabId,
  });
  final String orderId;

  /// TabInfo the order was placed on (existing or newly created), if any.
  final String? tabId;

  /// True when the server could not be reached: the order is queued and shown
  /// as "pending confirmation" until the outbox replay is confirmed.
  final bool queued;
  final Order? order;
}

final orderServiceProvider = Provider<OrderService>(OrderService.new);

/// Attendant order repository. Never prices anything: it sends product ids,
/// quantities and notes; the server prices, taxes and locks.
class OrderService {
  OrderService(this._ref);
  final Ref _ref;

  R007Api get _api => _ref.read(apiProvider);
  ConnectivityController get _conn => _ref.read(connectivityProvider.notifier);

  /// Executes one queueable operation against the API (used both for the live
  /// path and for outbox replay, with the SAME idempotency key).
  Future<Order?> execute(QueuedOp op) async {
    switch (op.type) {
      case OpType.openTable:
        await _api.openTable(
          op.payload['tableId'] as String,
          idempotencyKey: op.idempotencyKey,
        );
        return null;
      case OpType.openTab:
        await _api.openTab(
          id: op.payload['id'] as String,
          facilityId: op.payload['facilityId'] as String,
          tableId: op.payload['tableId'] as String?,
          customerName: op.payload['customerName'] as String?,
          idempotencyKey: op.idempotencyKey,
        );
        return null;
      case OpType.createOrder:
        return _api.createOrder(
          OrderDraft.fromJson(op.payload),
          idempotencyKey: op.idempotencyKey,
        );
      case OpType.sendOrder:
        return _api.sendOrder(
          op.payload['orderId'] as String,
          idempotencyKey: op.idempotencyKey,
        );
      default:
        throw ApiProblem(
          status: 400,
          code: 'validation_failed',
          title: 'Unknown queued action ${op.type}',
        );
    }
  }

  /// Creates + sends an order.
  ///
  /// * [openTable]: seat the table first (`POST /tables/{id}/open`).
  /// * [createTab]: open a new tab (for [customerName] and/or the table) and
  ///   put the order on it.
  ///
  /// Order of operations is preserved: if anything is already queued, this
  /// order is queued behind it rather than jumping the line.
  Future<SubmitResult> submit(
    OrderDraft draft, {
    bool openTable = false,
    bool createTab = false,
    String? customerName,
  }) async {
    final outbox = _ref.read(outboxProvider.notifier);
    final now = DateTime.now().toUtc();
    var d = draft.copyWith(createdAt: now);
    final ops = <QueuedOp>[];
    QueuedOp op(String type, Map<String, dynamic> payload) => QueuedOp(
      id: newId(),
      type: type,
      payload: payload,
      idempotencyKey: newId(),
      createdAt: now,
      orderId: draft.id,
    );

    if (openTable && d.tableId != null) {
      ops.add(op(OpType.openTable, {'tableId': d.tableId}));
    }
    if (createTab) {
      final tabId = newId();
      d = d.copyWith(tabId: tabId);
      ops.add(
        op(OpType.openTab, {
          'id': tabId,
          'facilityId': d.facilityId,
          'tableId': d.tableId,
          'customerName': customerName,
        }),
      );
    }
    ops
      ..add(op(OpType.createOrder, d.toJson()))
      ..add(op(OpType.sendOrder, {'orderId': d.id}));

    // Behind an existing queue: keep strict ordering.
    if (_ref.read(outboxProvider).hasPending) {
      await outbox.enqueueAll(ops);
      unawaited(outbox.drain());
      return SubmitResult(orderId: d.id, queued: true, tabId: d.tabId);
    }

    var i = 0;
    try {
      Order? last;
      for (; i < ops.length; i++) {
        last = await execute(ops[i]) ?? last;
      }
      _conn.reportOnline();
      return SubmitResult(
        orderId: d.id,
        queued: false,
        order: last,
        tabId: d.tabId,
      );
    } on ApiOfflineException {
      _conn.reportOffline();
      // Queue only the steps that did not complete (keys unchanged).
      await outbox.enqueueAll(ops.sublist(i));
      return SubmitResult(orderId: d.id, queued: true, tabId: d.tabId);
    }
  }

  Future<Order> markServed(String orderId) =>
      _guard(() => _api.markServed(orderId, idempotencyKey: newId()));

  /// Sensitive actions are never queued: they need an authoritative answer.
  Future<SensitiveResult> voidOrder(
    String orderId, {
    required String reason,
    String? stepUpToken,
  }) => _guard(
    () => _api.voidOrder(
      orderId,
      reason: reason,
      stepUpToken: stepUpToken,
      idempotencyKey: newId(),
    ),
  );

  Future<SensitiveResult> adjust(
    String orderId,
    String lineId, {
    required String kind,
    String? value,
    required String reason,
    String? stepUpToken,
  }) => _guard(
    () => _api.adjustLine(
      orderId,
      lineId,
      kind: kind,
      value: value,
      reason: reason,
      stepUpToken: stepUpToken,
      idempotencyKey: newId(),
    ),
  );

  Future<StepUp> stepUp({
    String? identifier,
    required String secret,
    required String credentialType,
    required String permission,
    String? entityId,
  }) => _guard(
    () => _api.stepUp(
      identifier: identifier,
      secret: secret,
      credentialType: credentialType,
      permission: permission,
      entityType: 'order',
      entityId: entityId,
    ),
  );

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      final r = await body();
      _conn.reportOnline();
      return r;
    } on ApiOfflineException {
      _conn.reportOffline();
      rethrow;
    }
  }
}
