import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:path_provider/path_provider.dart';

import '../api/r007_api.dart';
import '../storage/kv_store.dart';
import '../util/json.dart';

/// Types of operation that may be queued while the server is unreachable.
/// Ticket validation, payment SETTLEMENT, approvals, sports release/return
/// are NEVER queued (they need an authoritative live answer - spec/
/// architecture 13 §4). The one payment exception is a waiter's manual
/// cash / card-machine collection RECORD: it is only ever PENDING (a cashier
/// confirms it later) and carries a client UUIDv7 id, so replay is safe.
abstract final class OpType {
  static const openTab = 'tab.open';
  static const openTable = 'table.open';
  static const createOrder = 'order.create';
  static const sendOrder = 'order.send';

  /// Manual cash / card-machine collection record (CollectionRequest).
  /// Pay-link / transfer initiation is NEVER queued (needs the provider).
  static const collect = 'collection.record';
}

class QueuedOp {
  QueuedOp({
    required this.id,
    required this.type,
    required this.payload,
    required this.idempotencyKey,
    required this.createdAt,
    this.orderId,
    this.attempts = 0,
    this.failed = false,
    this.error,
  });

  factory QueuedOp.fromJson(Json j) => QueuedOp(
    id: j.str('id'),
    type: j.str('type'),
    payload: j.obj('payload'),
    idempotencyKey: j.str('idempotencyKey'),
    createdAt: j.date('createdAt') ?? DateTime.now().toUtc(),
    orderId: j.strOrNull('orderId'),
    attempts: j.intOr('attempts'),
    failed: j.boolOr('failed'),
    error: j.strOrNull('error'),
  );

  final String id;
  final String type;
  final Json payload;

  /// Generated when the user acted; re-sent unchanged on every replay.
  final String idempotencyKey;
  final DateTime createdAt;

  /// Order this op belongs to (for "pending confirmation" UI + dependency skip).
  final String? orderId;
  int attempts;
  bool failed;
  String? error;

  Json toJson() => {
    'id': id,
    'type': type,
    'payload': payload,
    'idempotencyKey': idempotencyKey,
    'createdAt': createdAt.toIso8601String(),
    'orderId': orderId,
    'attempts': attempts,
    'failed': failed,
    'error': error,
  };
}

/// Thrown when the queue is full or too stale to accept more work.
class QueueBlockedException implements Exception {
  const QueueBlockedException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Persistence for the (already encrypted) queue blob.
abstract class QueueStorage {
  Future<String?> read();
  Future<void> write(String data);
}

class MemoryQueueStorage implements QueueStorage {
  String? data;
  @override
  Future<String?> read() async => data;
  @override
  Future<void> write(String d) async => data = d;
}

class FileQueueStorage implements QueueStorage {
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/r007_offline_queue.bin');
  }

  @override
  Future<String?> read() async {
    final f = await _file();
    return f.existsSync() ? f.readAsString() : null;
  }

  @override
  Future<void> write(String data) async {
    final f = await _file();
    await f.writeAsString(data, flush: true);
  }
}

/// AES-256-GCM encryption for the queue at rest; the key lives in the
/// platform keystore (via [KvStore]) and never in the queue file.
class QueueCrypto {
  QueueCrypto(this._kv);
  final KvStore _kv;
  enc.Key? _key;

  Future<enc.Key> _loadKey() async {
    if (_key != null) return _key!;
    var b64 = await _kv.read(Keys.queueKey);
    if (b64 == null) {
      final rnd = Random.secure();
      b64 = base64Encode(
        Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256))),
      );
      await _kv.write(Keys.queueKey, b64);
    }
    return _key = enc.Key(base64Decode(b64));
  }

  Future<String> encrypt(String plain) async {
    final key = await _loadKey();
    final iv = enc.IV.fromSecureRandom(12);
    final e = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    final out = e.encrypt(plain, iv: iv);
    return '${iv.base64}:${out.base64}';
  }

  Future<String> decrypt(String blob) async {
    final key = await _loadKey();
    final parts = blob.split(':');
    final e = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    return e.decrypt(
      enc.Encrypted.fromBase64(parts[1]),
      iv: enc.IV.fromBase64(parts[0]),
    );
  }
}

typedef OpExecutor = Future<void> Function(QueuedOp op);

enum DrainOutcome { empty, drained, offline, authRequired }

/// Encrypted, bounded, ordered outbox.
///
/// * Replay is strictly in order, one request in flight at a time.
/// * Network failure stops the drain and keeps everything (retry later).
/// * A definitive server rejection (4xx problem) marks that op FAILED with the
///   server's message and skips other ops of the same order; it is surfaced,
///   never silently dropped.
/// * Bounded by count and age; when exceeded new work is refused so staff are
///   told to reconnect instead of accumulating unverifiable state.
class OfflineQueue {
  OfflineQueue({
    required this._storage,
    required this._crypto,
    this.maxItems = 50,
    this.maxAge = const Duration(minutes: 30),
    DateTime Function()? clock,
  }) : _now = clock ?? (() => DateTime.now().toUtc());

  final QueueStorage _storage;
  final QueueCrypto _crypto;
  final int maxItems;
  final Duration maxAge;
  final DateTime Function() _now;

  final List<QueuedOp> _items = [];
  final _changes = StreamController<List<QueuedOp>>.broadcast();
  bool _draining = false;
  bool _rerun = false;

  List<QueuedOp> get items => List.unmodifiable(_items);
  List<QueuedOp> get pending => _items.where((o) => !o.failed).toList();
  List<QueuedOp> get failed => _items.where((o) => o.failed).toList();
  Stream<List<QueuedOp>> get changes => _changes.stream;

  /// True when the queue refuses new work (full, or oldest op too stale).
  bool get isBlocked => blockReason != null;

  String? get blockReason {
    final p = pending;
    if (p.length >= maxItems) {
      return 'Too many unsent actions (${p.length}). Reconnect to continue.';
    }
    if (p.isNotEmpty && _now().difference(p.first.createdAt) > maxAge) {
      return 'Unsent actions are too old to trust. Reconnect to confirm them.';
    }
    return null;
  }

  Future<void> load() async {
    final blob = await _storage.read();
    _items.clear();
    if (blob != null && blob.isNotEmpty) {
      try {
        final list = jsonDecode(await _crypto.decrypt(blob)) as List<dynamic>;
        _items.addAll(
          list.whereType<Map<String, dynamic>>().map(QueuedOp.fromJson),
        );
      } on Object {
        // Unreadable (key lost / corrupt): start clean rather than crash.
        _items.clear();
      }
    }
    _notify();
  }

  Future<void> _persist() async {
    final blob = await _crypto.encrypt(
      jsonEncode([for (final o in _items) o.toJson()]),
    );
    await _storage.write(blob);
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(items);
  }

  /// Enqueue one or more ops atomically (all or none).
  Future<void> enqueueAll(List<QueuedOp> ops) async {
    final reason = blockReason;
    if (reason != null) throw QueueBlockedException(reason);
    if (pending.length + ops.length > maxItems) {
      throw const QueueBlockedException(
        'Too many unsent actions. Reconnect to continue.',
      );
    }
    _items.addAll(ops);
    await _persist();
    _notify();
  }

  Future<void> dismiss(String opId) async {
    _items.removeWhere((o) => o.id == opId);
    await _persist();
    _notify();
  }

  Future<void> clearFailed() async {
    _items.removeWhere((o) => o.failed);
    await _persist();
    _notify();
  }

  bool hasPendingFor(String orderId) =>
      _items.any((o) => o.orderId == orderId && !o.failed);

  /// Replays pending ops in order. Safe to call concurrently: a call made while
  /// a replay is running is remembered, and if that replay stops on a network
  /// error it is retried once (the caller may have just regained connectivity).
  Future<DrainOutcome> drain(
    OpExecutor execute, {
    void Function(QueuedOp op)? onDone,
    void Function(QueuedOp op)? onFailed,
  }) async {
    if (_draining) {
      _rerun = true;
      return DrainOutcome.drained;
    }
    var out = await _drainOnce(execute, onDone: onDone, onFailed: onFailed);
    while (_rerun && out == DrainOutcome.offline) {
      _rerun = false;
      out = await _drainOnce(execute, onDone: onDone, onFailed: onFailed);
    }
    _rerun = false;
    return out;
  }

  Future<DrainOutcome> _drainOnce(
    OpExecutor execute, {
    void Function(QueuedOp op)? onDone,
    void Function(QueuedOp op)? onFailed,
  }) async {
    if (pending.isEmpty) return DrainOutcome.empty;
    _draining = true;
    try {
      final skipOrders = <String>{};
      for (final op in List<QueuedOp>.of(pending)) {
        if (op.orderId != null && skipOrders.contains(op.orderId)) {
          op
            ..failed = true
            ..error = 'Skipped: an earlier step of this order was rejected';
          onFailed?.call(op);
          continue;
        }
        op.attempts++;
        try {
          await execute(op);
          _items.remove(op);
          onDone?.call(op);
        } on ApiOfflineException {
          await _persist();
          _notify();
          return DrainOutcome.offline;
        } on ApiProblem catch (e) {
          if (e.isUnauthorized) {
            await _persist();
            _notify();
            return DrainOutcome.authRequired;
          }
          if (e.status >= 500 || e.status == 429 || e.status == 408) {
            await _persist();
            _notify();
            return DrainOutcome.offline; // transient: retry later, keep order
          }
          op
            ..failed = true
            ..error = e.message;
          if (op.orderId != null) skipOrders.add(op.orderId!);
          onFailed?.call(op);
        }
        await _persist();
        _notify();
      }
      return DrainOutcome.drained;
    } finally {
      _draining = false;
      _notify();
    }
  }

  void dispose() => unawaited(_changes.close());
}
