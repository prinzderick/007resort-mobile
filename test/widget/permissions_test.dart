import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/app/router.dart';
import 'package:r007_mobile/core/config/app_config.dart';
import 'package:r007_mobile/core/models/models.dart';
import 'package:r007_mobile/core/state/app_state.dart';
import 'package:r007_mobile/core/state/board.dart';

import '../helpers/harness.dart';

const mockCfg = AppConfig(
  useMock: true,
  presetApiBaseUrl: '',
  environment: 'test',
);
const realCfg = AppConfig(
  useMock: false,
  presetApiBaseUrl: '',
  environment: 'test',
);

DeviceIdentity dev(String kind, {String? home, String? homeKind}) =>
    DeviceIdentity(
      deviceId: 'd',
      deviceToken: 't',
      kind: kind,
      homeFacilityId: home,
      homeFacilityKind: homeKind,
    );

AuthSession sess({bool locked = false}) => AuthSession(
  accessToken: 'a',
  refreshToken: 'r',
  expiresAt: DateTime.utc(2030),
  staff: const Staff(id: 's', name: 'X'),
);

void main() {
  group('route gating (what each tablet/staff state may see)', () {
    test('real mode needs a server URL first, then enrolment, then login', () {
      expect(baseRouteFor(const AppState(), realCfg), Routes.setup);
      expect(
        baseRouteFor(const AppState(serverUrl: 'http://x'), realCfg),
        Routes.enrol,
      );
      expect(baseRouteFor(const AppState(), mockCfg), Routes.enrol);
      expect(
        baseRouteFor(AppState(device: dev('MOBILE_TABLET')), mockCfg),
        Routes.login,
      );
    });

    test('attendant must check out before seeing tables; locked wins', () {
      final s = AppState(device: dev('MOBILE_TABLET'), session: sess());
      expect(baseRouteFor(s, mockCfg), Routes.checkout);
      expect(
        baseRouteFor(
          s.copyWith(
            checkout: const Checkout(
              facility: Facility(id: 'f', name: 'R'),
            ),
          ),
          mockCfg,
        ),
        Routes.attendant,
      );
      expect(baseRouteFor(s.copyWith(locked: true), mockCfg), Routes.locked);
    });

    test('mode-specific home screens', () {
      String route(DeviceIdentity d) =>
          baseRouteFor(AppState(device: d, session: sess()), mockCfg);
      expect(
        route(dev('MOBILE_TABLET', home: 'f', homeKind: 'RESTAURANT')),
        Routes.supervisor,
      );
      expect(
        route(dev('MOBILE_TABLET', home: 'f', homeKind: 'SPORTS_STORE')),
        Routes.store,
      );
      expect(route(dev('ENTRANCE_SCANNER', home: 'f')), Routes.entrance);
      // unknown role never unlocks a UI
      expect(route(dev('POS_TERMINAL')), Routes.unresolved);
      expect(route(dev('MOBILE_TABLET', home: 'f')), Routes.unresolved);
    });
  });

  test('Staff.can gates strictly on permission strings, not roles', () {
    const s = Staff(id: 'x', name: 'Y', permissions: {'order.create'});
    expect(s.can('order.create'), isTrue);
    expect(s.can('order.void.execute'), isFalse);
    expect(s.can('Manager'), isFalse);
  });

  testWidgets(
    'trainee (no void.execute): UI says "Void (supervisor)"; supervisor PIN authorises inline',
    (tester) async {
      final h = Harness();
      await h.pump(tester);
      await enrolAs(tester, 'ATT-2026');
      await loginWith(tester, 'chidi', '2345');
      await tester.tap(find.byKey(const Key('facility-f-restaurant')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('checkout-submit')));
      await settle(tester);

      await tester.tap(find.byKey(const Key('table-tbl-f-restaurant-5')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('add-order')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('product-p-suya')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-order')));
      await settle(tester);
      final order = h.container.read(boardProvider).orders.single;

      expect(find.text('Void (supervisor)'), findsOneWidget);
      expect(find.text('Void order'), findsNothing);
      await tester.tap(find.byKey(Key('void-${order.id}')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('reason-field')),
        'Customer changed mind',
      );
      await tester.tap(find.byKey(const Key('reason-confirm')));
      await settle(tester);
      // supervisor authorisation dialog (NOT the trainee's own PIN)
      expect(find.textContaining('supervisor authorisation'), findsOneWidget);
      // a non-supervisor's PIN is refused by the server
      await tester.enterText(
        find.byKey(const Key('stepup-identifier')),
        'amaka',
      );
      await tester.enterText(find.byKey(const Key('stepup-pin')), '1234');
      await tester.tap(find.byKey(const Key('stepup-confirm')));
      await settle(tester);
      expect(h.container.read(boardProvider).orders.single.status, 'SENT');
    },
  );

  testWidgets('trainee void with a real supervisor PIN succeeds', (
    tester,
  ) async {
    final h = Harness();
    await h.pump(tester);
    await enrolAs(tester, 'ATT-2026');
    await loginWith(tester, 'chidi', '2345');
    await tester.tap(find.byKey(const Key('facility-f-restaurant')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('checkout-submit')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('table-tbl-f-restaurant-5')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('add-order')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('product-p-suya')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('send-order')));
    await settle(tester);
    final order = h.container.read(boardProvider).orders.single;
    await tester.tap(find.byKey(Key('void-${order.id}')));
    await settle(tester);
    await tester.enterText(
      find.byKey(const Key('reason-field')),
      'Wrong table',
    );
    await tester.tap(find.byKey(const Key('reason-confirm')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('stepup-identifier')), 'ngozi');
    await tester.enterText(find.byKey(const Key('stepup-pin')), '9999');
    await tester.tap(find.byKey(const Key('stepup-confirm')));
    await settle(tester);
    expect(h.container.read(boardProvider).orders, isEmpty); // voided => closed
  });

  testWidgets(
    'waiter WITH execute but not approve: void becomes a pending approval',
    (tester) async {
      final h = Harness();
      await h.pump(tester);
      await enrolAs(tester, 'ATT-2026');
      await loginWith(tester, 'amaka', '1234');
      await tester.tap(find.byKey(const Key('facility-f-restaurant')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('checkout-submit')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('table-tbl-f-restaurant-6')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('add-order')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('product-p-suya')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-order')));
      await settle(tester);
      final order = h.container.read(boardProvider).orders.single;
      expect(find.text('Void order'), findsOneWidget);
      await tester.tap(find.byKey(Key('void-${order.id}')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('reason-field')), 'Spilled');
      await tester.tap(find.byKey(const Key('reason-confirm')));
      await settle(tester);
      expect(find.text('Sent to a supervisor for approval'), findsOneWidget);
      expect(
        h.container.read(boardProvider).orders.single.status,
        'PENDING_APPROVAL',
      );
      expect(find.text('Waiting for a supervisor to approve.'), findsOneWidget);
      // order actions are frozen while awaiting approval
      expect(find.byKey(Key('void-${order.id}')), findsNothing);
    },
  );
}
