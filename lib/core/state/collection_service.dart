import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/r007_api.dart';
import '../models/collection_models.dart';
import '../models/models.dart';
import '../offline/offline_queue.dart';
import '../util/json.dart';
import 'app_state.dart';
import 'board.dart';
import 'connectivity.dart';
import 'outbox.dart';

/// Result of recording a collection.
class CollectResult {
  const CollectResult({required this.queued, this.collection});

  /// True when the server could not be reached and the (cash / card-machine)
  /// record was saved on the tablet ("pending sync").
  final bool queued;
  final Collection? collection;
}

final collectionServiceProvider = Provider<CollectionService>(
  CollectionService.new,
);

/// Waiter collection repository.
///
/// * Never marks anything paid: the server answers PENDING_CONFIRMATION /
///   AWAITING_PAYMENT and the cashier / provider confirms.
/// * Money is sent as the exact strings the waiter typed; the server does all
///   the maths and validation (remaining, limits, change).
/// * Only manual records (cash, card machine) may be queued offline; a pay
///   link / transfer account needs the provider, so it needs the network.
class CollectionService {
  CollectionService(this._ref);
  final Ref _ref;

  R007Api get _api => _ref.read(apiProvider);
  ConnectivityController get _conn => _ref.read(connectivityProvider.notifier);

  /// Executes a queued collection (live path and outbox replay share it).
  Future<void> execute(QueuedOp op) async {
    await _api.createCollection(
      CollectionRequest.fromJson(op.payload),
      idempotencyKey: op.idempotencyKey,
    );
  }

  Future<Order> printBill(String orderId) =>
      _guard(() => _api.printBill(orderId, idempotencyKey: newId()));

  /// Records / initiates a tender. [idempotencyKey] must be the SAME for every
  /// retry of the same on-screen attempt (the request [CollectionRequest.id]
  /// is the client UUIDv7 that makes the server replay-safe).
  Future<CollectResult> collect(
    CollectionRequest req, {
    required String idempotencyKey,
  }) async {
    final outbox = _ref.read(outboxProvider.notifier);
    QueuedOp op() => QueuedOp(
      id: newId(),
      type: OpType.collect,
      payload: req.toJson(),
      idempotencyKey: idempotencyKey,
      createdAt: DateTime.now().toUtc(),
      orderId: req.orderId,
    );

    final queueable = TenderMethod.queueable(req.method);
    // Keep order: never jump ahead of unsent work for the same tablet.
    if (queueable && _ref.read(outboxProvider).hasPending) {
      await outbox.enqueueAll([op()]);
      unawaited(outbox.drain());
      return const CollectResult(queued: true);
    }
    try {
      final c = await _api.createCollection(
        req,
        idempotencyKey: idempotencyKey,
      );
      _conn.reportOnline();
      return CollectResult(queued: false, collection: c);
    } on ApiOfflineException {
      _conn.reportOffline();
      if (!queueable) rethrow; // pay link / transfer need the network
      await outbox.enqueueAll([op()]);
      return const CollectResult(queued: true);
    }
  }

  /// Polling fallback for a pay link / transfer: ask the server to verify it
  /// with the provider. Never throws (it is only a nudge).
  Future<void> verifyProvider(String reference) async {
    try {
      await _api.verifyProviderPayment(reference);
    } on Object {
      // best effort
    }
  }

  Future<List<Collection>> collections(String orderId) =>
      _guard(() => _api.listCollections(orderId));

  Future<CashInHand> cashInHand(String staffId) =>
      _guard(() => _api.cashInHand(staffId));

  Future<List<Collection>> myCollectionsSince(String staffId, DateTime since) =>
      _guard(() => _api.listMyCollections(staffId, since: since));

  Future<List<CashHandover>> handovers(String staffId) =>
      _guard(() => _api.listHandovers(staffId));

  /// Handover needs an authoritative answer (variance): never queued.
  Future<CashHandover> handover({
    required String id,
    required String declaredAmount,
    String? note,
    required String idempotencyKey,
  }) => _guard(
    () => _api.createHandover(
      id: id,
      declaredAmount: declaredAmount,
      note: note,
      idempotencyKey: idempotencyKey,
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

/// Effective collection policy of the signed-in waiter at the current
/// facility. Reloaded on login / checkout / facility change; last known copy is
/// cached so an offline tablet keeps behaving (the server still enforces).
final collectionPolicyProvider = FutureProvider<CollectionPolicy>((ref) async {
  final staffId = ref.watch(appControllerProvider.select((s) => s.staff?.id));
  final facilityId = ref.watch(
    appControllerProvider.select((s) => s.facilityId),
  );
  // Re-read about once a minute (10 s board polls) so a change made by IT
  // (facility rule or per-staff override) reaches a tablet mid-shift.
  ref.watch(boardProvider.select((b) => b.revision ~/ 6));
  if (staffId == null) return CollectionPolicy.permissive;
  final kv = ref.read(kvStoreProvider);
  final key = 'r007.collection-policy.$staffId.$facilityId';
  try {
    final p = await ref
        .read(apiProvider)
        .collectionPolicy(staffId, facilityId: facilityId);
    await kv.write(key, jsonEncode(p.toJson()));
    return p;
  } on ApiOfflineException {
    final cached = await kv.read(key);
    if (cached != null) {
      return CollectionPolicy.fromJson(jsonDecode(cached) as Json);
    }
    return CollectionPolicy.permissive;
  } on ApiProblem {
    return CollectionPolicy.permissive;
  }
});

/// Server collections of an order; reloads on every board refresh (realtime
/// hint or the 10 s poll).
final orderCollectionsProvider = FutureProvider.autoDispose
    .family<List<Collection>, String>((ref, orderId) async {
      ref.watch(boardProvider.select((b) => b.revision));
      final svc = ref.read(collectionServiceProvider);
      final list = await svc.collections(orderId);
      // Pay links / provider transfers still waiting: nudge the server to
      // verify them with the provider (no webhook reaches a local node); the
      // result shows on the next refresh.
      for (final c in list) {
        if (c.isWaiting && c.providerReference != null) {
          unawaited(svc.verifyProvider(c.providerReference!));
        }
      }
      return list..sort(
        (a, b) => (b.collectedAt ?? DateTime(0)).compareTo(
          a.collectedAt ?? DateTime(0),
        ),
      );
    });

/// Records queued offline for an order, shown as "pending sync".
final pendingSyncCollectionsProvider =
    Provider.family<List<Collection>, String>((ref, orderId) {
      final box = ref.watch(outboxProvider);
      return [
        for (final op in [...box.pending, ...box.failed])
          if (op.type == OpType.collect && op.orderId == orderId)
            CollectionRequest.fromJson(op.payload).toPendingSync(),
      ];
    });

/// Cash in hand (server position, limit, handover-required flag).
final cashInHandProvider = FutureProvider.autoDispose<CashInHand>((ref) async {
  final staffId = ref.watch(appControllerProvider.select((s) => s.staff?.id));
  ref.watch(boardProvider.select((b) => b.revision));
  if (staffId == null) return const CashInHand();
  return ref.read(collectionServiceProvider).cashInHand(staffId);
});

/// Today's collections of this waiter (every tender, every status).
final myCollectionsTodayProvider = FutureProvider.autoDispose<List<Collection>>(
  (ref) async {
    final staffId = ref.watch(appControllerProvider.select((s) => s.staff?.id));
    ref.watch(boardProvider.select((b) => b.revision));
    if (staffId == null) return const [];
    final now = DateTime.now();
    final list = await ref
        .read(collectionServiceProvider)
        .myCollectionsSince(staffId, DateTime(now.year, now.month, now.day));
    return list..sort(
      (a, b) => (b.collectedAt ?? DateTime(0)).compareTo(
        a.collectedAt ?? DateTime(0),
      ),
    );
  },
);

/// Recent handovers (status + variance once the cashier has counted).
final myHandoversProvider = FutureProvider.autoDispose<List<CashHandover>>((
  ref,
) async {
  final staffId = ref.watch(appControllerProvider.select((s) => s.staff?.id));
  ref.watch(boardProvider.select((b) => b.revision));
  if (staffId == null) return const [];
  return ref.read(collectionServiceProvider).handovers(staffId);
});
