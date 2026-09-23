import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/api/r007_api.dart';
import 'package:r007_mobile/core/offline/offline_queue.dart';
import 'package:r007_mobile/core/storage/kv_store.dart';

QueuedOp op(String id, {String? orderId, DateTime? at}) => QueuedOp(
  id: id,
  type: OpType.sendOrder,
  payload: {'orderId': orderId ?? id, 'secret-note': 'plaintext-marker'},
  idempotencyKey: 'key-$id',
  createdAt: at ?? DateTime.now().toUtc(),
  orderId: orderId ?? id,
);

OfflineQueue newQueue({
  MemoryQueueStorage? storage,
  MemoryKvStore? kv,
  int maxItems = 50,
  Duration maxAge = const Duration(minutes: 30),
  DateTime Function()? clock,
}) => OfflineQueue(
  storage: storage ?? MemoryQueueStorage(),
  crypto: QueueCrypto(kv ?? MemoryKvStore()),
  maxItems: maxItems,
  maxAge: maxAge,
  clock: clock,
);

void main() {
  test(
    'replays strictly in order with the original idempotency keys',
    () async {
      final q = newQueue();
      await q.enqueueAll([op('a'), op('b'), op('c')]);
      final seen = <String>[];
      final out = await q.drain(
        (o) async => seen.add('${o.id}:${o.idempotencyKey}'),
      );
      expect(out, DrainOutcome.drained);
      expect(seen, ['a:key-a', 'b:key-b', 'c:key-c']);
      expect(q.pending, isEmpty);
    },
  );

  test(
    'a network error stops the drain and keeps everything, in order',
    () async {
      final q = newQueue();
      await q.enqueueAll([op('a'), op('b'), op('c')]);
      var calls = 0;
      final out = await q.drain((o) async {
        calls++;
        if (o.id == 'b') throw const ApiOfflineException();
      });
      expect(out, DrainOutcome.offline);
      expect(calls, 2);
      expect(q.pending.map((o) => o.id), ['b', 'c']);
      // next drain retries b first with the SAME key
      final seen = <String>[];
      await q.drain((o) async => seen.add(o.idempotencyKey));
      expect(seen, ['key-b', 'key-c']);
    },
  );

  test(
    'a server rejection is surfaced (not dropped) and skips that order only',
    () async {
      final q = newQueue();
      await q.enqueueAll([
        op('a1', orderId: 'A'),
        op('a2', orderId: 'A'),
        op('b1', orderId: 'B'),
      ]);
      final done = <String>[];
      final failed = <String>[];
      await q.drain(
        (o) async {
          if (o.id == 'a1') {
            throw const ApiProblem(
              status: 422,
              code: 'validation_failed',
              title: 'Product gone',
            );
          }
        },
        onDone: (o) => done.add(o.id),
        onFailed: (o) => failed.add(o.id),
      );
      expect(done, ['b1']);
      expect(failed, ['a1', 'a2']);
      expect(q.failed.map((o) => o.error).first, 'Product gone');
      expect(q.pending, isEmpty);
      await q.dismiss('a1');
      expect(q.failed.map((o) => o.id), ['a2']);
    },
  );

  test('5xx/429 are transient: kept for retry', () async {
    final q = newQueue();
    await q.enqueueAll([op('a')]);
    final out = await q.drain((o) async {
      throw const ApiProblem(status: 503, code: 'server_error');
    });
    expect(out, DrainOutcome.offline);
    expect(q.pending, hasLength(1));
    expect(q.failed, isEmpty);
  });

  test('401 stops the drain and asks for re-authentication', () async {
    final q = newQueue();
    await q.enqueueAll([op('a')]);
    final out = await q.drain((o) async {
      throw const ApiProblem(status: 401, code: 'unauthenticated');
    });
    expect(out, DrainOutcome.authRequired);
    expect(q.pending, hasLength(1));
  });

  test('bounded by count: refuses new work when full', () async {
    final q = newQueue(maxItems: 3);
    await q.enqueueAll([op('a'), op('b'), op('c')]);
    expect(q.isBlocked, isTrue);
    expect(
      () => q.enqueueAll([op('d')]),
      throwsA(isA<QueueBlockedException>()),
    );
  });

  test('bounded by age: too-stale items block new work', () async {
    var now = DateTime.utc(2026, 9, 23, 12);
    final q = newQueue(clock: () => now);
    await q.enqueueAll([op('a', at: now)]);
    expect(q.isBlocked, isFalse);
    now = now.add(const Duration(minutes: 31));
    expect(q.isBlocked, isTrue);
    expect(q.blockReason, contains('too old'));
    expect(
      () => q.enqueueAll([op('b')]),
      throwsA(isA<QueueBlockedException>()),
    );
  });

  test('persisted encrypted at rest and restored after restart', () async {
    final storage = MemoryQueueStorage();
    final kv = MemoryKvStore();
    final q = newQueue(storage: storage, kv: kv);
    await q.enqueueAll([op('a'), op('b')]);

    final raw = storage.data!;
    expect(raw, isNot(contains('plaintext-marker')));
    expect(raw, isNot(contains('orderId')));
    expect(kv.data.containsKey(Keys.queueKey), isTrue);

    // "restart": a new queue over the same storage + keystore
    final q2 = newQueue(storage: storage, kv: kv);
    await q2.load();
    expect(q2.pending.map((o) => o.id), ['a', 'b']);
    expect(q2.pending.first.payload['secret-note'], 'plaintext-marker');
  });

  test(
    'a queue that cannot be decrypted starts clean instead of crashing',
    () async {
      final storage = MemoryQueueStorage();
      final q = newQueue(storage: storage);
      await q.enqueueAll([op('a')]);
      // new keystore => different key => undecryptable
      final q2 = newQueue(storage: storage, kv: MemoryKvStore());
      await q2.load();
      expect(q2.items, isEmpty);
    },
  );

  test('tampered ciphertext is rejected (GCM authentication)', () async {
    final storage = MemoryQueueStorage();
    final kv = MemoryKvStore();
    final q = newQueue(storage: storage, kv: kv);
    await q.enqueueAll([op('a')]);
    final parts = storage.data!.split(':');
    final bytes = parts[1].codeUnits.toList();
    bytes[4] = bytes[4] == 65 ? 66 : 65;
    storage.data = '${parts[0]}:${String.fromCharCodes(bytes)}';
    final q2 = newQueue(storage: storage, kv: kv);
    await q2.load();
    expect(q2.items, isEmpty);
  });
}
