import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/models/models.dart';
import 'package:r007_mobile/core/state/sports.dart';

import '../helpers/harness.dart';

Future<Harness> entrance(WidgetTester tester) async {
  final h = Harness();
  await h.pump(tester);
  await enrolAs(tester, 'ENT-2026', kind: 'ENTRANCE_SCANNER');
  await loginWith(tester, 'sports1', '5555');
  return h;
}

Future<void> scan(WidgetTester tester, Harness h, String code) async {
  h.scannerCallback!(code);
  await settle(tester);
}

void main() {
  testWidgets(
    'entrance: VALID then USED on the second scan (no double entry)',
    (tester) async {
      final h = await entrance(tester);
      expect(find.byKey(const Key('fake-scanner')), findsOneWidget);

      await scan(tester, h, 'R007-DEMO-VALID-1');
      expect(find.byKey(const Key('result-view')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('result-headline'))).data,
        'VALID',
      );
      expect(find.text('Adaeze N. (adult)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('next-scan')));
      await settle(tester);

      await scan(tester, h, 'R007-DEMO-VALID-1');
      expect(
        tester.widget<Text>(find.byKey(const Key('result-headline'))).data,
        'ALREADY USED',
      );
      await tester.tap(find.byKey(const Key('next-scan')));
      await settle(tester);
      // history lists both scans
      expect(find.byKey(const Key('scan-history')), findsOneWidget);
      expect(h.container.read(entranceProvider).history, hasLength(2));
    },
  );

  for (final c in {
    'R007-DEMO-EXPIRED': 'EXPIRED',
    'R007-DEMO-WRONG': 'WRONG FACILITY',
    'R007-DEMO-FUTURE': 'NOT YET VALID',
    'R007-DEMO-CANCELLED': 'CANCELLED',
    'NOT-A-REAL-CODE': 'NOT RECOGNISED',
  }.entries) {
    testWidgets('entrance: ${c.value} is unmistakable', (tester) async {
      final h = await entrance(tester);
      await scan(tester, h, c.key);
      expect(
        tester.widget<Text>(find.byKey(const Key('result-headline'))).data,
        c.value,
      );
    });
  }

  testWidgets('entrance: typed/wedge code entry works', (tester) async {
    await entrance(tester);
    await tester.enterText(
      find.byKey(const Key('code-field')),
      'R007-DEMO-VALID-2',
    );
    await tester.tap(find.byKey(const Key('code-submit')));
    await settle(tester);
    expect(
      tester.widget<Text>(find.byKey(const Key('result-headline'))).data,
      'VALID',
    );
  });

  testWidgets(
    'entrance offline: NEVER guesses - shows NO CONNECTION, retry redeems exactly once',
    (tester) async {
      final h = await entrance(tester);
      h.api.setOffline(true);
      await scan(tester, h, 'R007-DEMO-VALID-2');
      expect(find.byKey(const Key('connection-error')), findsOneWidget);
      expect(find.byKey(const Key('result-view')), findsNothing);
      expect(find.text('NO CONNECTION'), findsOneWidget);
      expect(h.container.read(entranceProvider).history, isEmpty);

      h.api.setOffline(false);
      await tester.tap(find.byKey(const Key('conn-retry')));
      await settle(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('result-headline'))).data,
        'VALID',
      );
      // and it was consumed exactly once
      await tester.tap(find.byKey(const Key('next-scan')));
      await settle(tester);
      await scan(tester, h, 'R007-DEMO-VALID-2');
      expect(
        tester.widget<Text>(find.byKey(const Key('result-headline'))).data,
        'ALREADY USED',
      );
    },
  );

  testWidgets(
    'store: shows what was paid/rented; release then duplicate is blocked',
    (tester) async {
      final h = Harness();
      await h.pump(tester);
      await enrolAs(tester, 'STO-2026');
      await loginWith(tester, 'sports1', '5555');
      await tester.tap(find.byKey(const Key('demo-R007-DEMO-STORE-1')));
      await settle(tester);

      expect(find.text('Emeka U.'), findsOneWidget);
      expect(find.text('1 x Tennis court - 1 hour'), findsOneWidget);
      expect(find.text('2 x Tennis racket (rental)'), findsOneWidget);
      expect(find.text('3 x Bottled water'), findsOneWidget);
      expect(find.text('NOT RELEASED'), findsWidgets);

      // select the racket and release it
      await tester.tap(find.byKey(const Key('item-i-racket')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('release-btn')));
      await settle(tester);
      expect(find.text('RELEASED - NOT RETURNED'), findsOneWidget);
      expect(find.byKey(const Key('store-notice')), findsOneWidget);

      // a second attempt on the same items cannot even be selected (server truth)
      final ent = h.container.read(storeProvider).entitlement!;
      final racket = ent.items.firstWhere((i) => i.id == 'i-racket');
      expect(racket.canRelease, isFalse);
      // ...and if forced through the API, the server blocks the duplicate
      await h.container.read(storeProvider.notifier).release(['i-racket']);
      await settle(tester);
      expect(find.textContaining('already released'), findsOneWidget);

      // record the return
      await tester.tap(find.byKey(const Key('item-i-racket')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('return-btn')));
      await settle(tester);
      expect(find.text('RETURNED'), findsOneWidget);
    },
  );

  testWidgets('store offline shows a connection error, releases nothing', (
    tester,
  ) async {
    final h = Harness();
    await h.pump(tester);
    await enrolAs(tester, 'STO-2026');
    await loginWith(tester, 'sports1', '5555');
    h.api.setOffline(true);
    await tester.tap(find.byKey(const Key('demo-R007-DEMO-STORE-1')));
    await settle(tester);
    expect(find.textContaining('Cannot reach the server'), findsWidgets);
    expect(h.container.read(storeProvider).entitlement, isNull);
  });

  test('scan outcome parsing tolerates unknown values', () {
    expect(ScanOutcome.fromWire('WRONG_FACILITY'), ScanOutcome.wrongFacility);
    expect(ScanOutcome.fromWire('something-new'), ScanOutcome.unknown);
    expect(ScanOutcome.fromWire(null), ScanOutcome.unknown);
  });
}
