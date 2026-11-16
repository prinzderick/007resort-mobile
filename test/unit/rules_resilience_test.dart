import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/api/r007_api.dart';
import 'package:r007_mobile/core/models/models.dart';
import 'package:r007_mobile/core/state/attendant_state.dart';
import 'package:r007_mobile/core/storage/kv_store.dart';

void main() {
  const waiterOnly = FacilityRules(waiterOnly: true, allowOpenTabs: true);

  test(
    'rules: a failing request keeps the last known waiter-only setting',
    () async {
      final kv = MemoryKvStore();
      expect(
        (await loadRulesResilient(() async => waiterOnly, kv, 'k')).waiterOnly,
        isTrue,
      );
      for (final failure in <Future<FacilityRules> Function()>[
        () async => throw const ApiOfflineException('no network'),
        () async => throw StateError('unreadable answer'),
        () => Future<FacilityRules>.delayed(
          const Duration(seconds: 30),
          () => const FacilityRules(),
        ),
      ]) {
        final r = await loadRulesResilient(
          failure,
          kv,
          'k',
        ).timeout(const Duration(seconds: 20));
        expect(
          r.waiterOnly,
          isTrue,
          reason: 'must not fall back to the standard flow',
        );
      }
    },
  );

  test(
    'rules: with nothing remembered a failure gives the plain default',
    () async {
      final r = await loadRulesResilient(
        () async => throw StateError('x'),
        MemoryKvStore(),
        'k',
      );
      expect(r.waiterOnly, isFalse);
    },
  );

  test(
    'rules: a real change from the server replaces what was remembered',
    () async {
      final kv = MemoryKvStore();
      await loadRulesResilient(() async => waiterOnly, kv, 'k');
      await loadRulesResilient(() async => const FacilityRules(), kv, 'k');
      expect(
        (await loadRulesResilient(
          () async => throw StateError('x'),
          kv,
          'k',
        )).waiterOnly,
        isFalse,
      );
    },
  );
}
