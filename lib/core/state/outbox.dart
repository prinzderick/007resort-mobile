import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../offline/offline_queue.dart';
import 'app_state.dart';
import 'connectivity.dart';
import 'order_service.dart';

final offlineQueueProvider = Provider<OfflineQueue>((ref) {
  final q = OfflineQueue(
    storage: FileQueueStorage(),
    crypto: QueueCrypto(ref.read(kvStoreProvider)),
  );
  ref.onDispose(q.dispose);
  return q;
});

class OutboxState {
  const OutboxState({
    this.pending = const [],
    this.failed = const [],
    this.blockReason,
    this.draining = false,
  });
  final List<QueuedOp> pending;
  final List<QueuedOp> failed;
  final String? blockReason;
  final bool draining;
  bool get hasPending => pending.isNotEmpty;

  /// Orders created offline and awaiting server confirmation.
  Set<String> get pendingOrderIds => {
    for (final o in pending)
      // A queued collection belongs to an order that already EXISTS on the
      // server, so it must not make the whole order look unconfirmed.
      if (o.orderId != null && o.type != OpType.collect) o.orderId!,
  };
}

final outboxProvider = NotifierProvider<OutboxController, OutboxState>(
  OutboxController.new,
);

/// UI-facing wrapper of the encrypted [OfflineQueue].
class OutboxController extends Notifier<OutboxState> {
  StreamSubscription<List<QueuedOp>>? _sub;

  /// Fires after ops were confirmed by the server (so boards can refresh).
  final _confirmed = StreamController<QueuedOp>.broadcast();
  Stream<QueuedOp> get confirmed => _confirmed.stream;

  @override
  OutboxState build() {
    final q = ref.watch(offlineQueueProvider);
    _sub = q.changes.listen((_) => state = _snapshot(q));
    ref.onDispose(() {
      unawaited(_sub?.cancel());
      unawaited(_confirmed.close());
    });
    unawaited(q.load());
    return _snapshot(q, draining: false);
  }

  OutboxState _snapshot(OfflineQueue q, {bool? draining}) => OutboxState(
    pending: q.pending,
    failed: q.failed,
    blockReason: q.blockReason,
    draining: draining ?? state.draining,
  );

  OfflineQueue get queue => ref.read(offlineQueueProvider);

  Future<void> enqueueAll(List<QueuedOp> ops) => queue.enqueueAll(ops);
  Future<void> dismiss(String id) => queue.dismiss(id);
  Future<void> clearFailed() => queue.clearFailed();

  Future<void> _execute(QueuedOp op) async {
    await ref.read(orderServiceProvider).execute(op);
  }

  /// Replays the queue in order. Called on reconnect and periodically.
  Future<DrainOutcome> drain() async {
    final q = queue;
    if (q.pending.isEmpty) return DrainOutcome.empty;
    state = _snapshot(q, draining: true);
    final outcome = await q.drain(_execute, onDone: _confirmed.add);
    state = _snapshot(q, draining: false);
    final conn = ref.read(connectivityProvider.notifier);
    if (outcome == DrainOutcome.offline) {
      conn.reportOffline();
    } else if (outcome == DrainOutcome.drained) {
      conn.reportOnline();
    }
    return outcome;
  }
}
