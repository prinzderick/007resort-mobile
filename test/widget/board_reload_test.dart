import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/state/app_state.dart';
import 'package:r007_mobile/core/state/board.dart';

import '../helpers/harness.dart';

/// Regression: after signing out and in again (or after a facility change) the board is rebuilt. It used to stay switched
/// off for good, so the tablet showed an endless spinner and no tables until the app was force-closed.
void main() {
  testWidgets('board loads again after signing out and back in', (
    tester,
  ) async {
    final h = Harness();
    await h.pump(tester);
    await enrolAs(tester, 'ATT-2026');
    await loginWith(tester, 'amaka', '1234');
    await tester.tap(find.byKey(const Key('facility-f-restaurant')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('checkout-submit')));
    await settle(tester);
    expect(
      h.container.read(boardProvider).loaded,
      isTrue,
      reason: 'first sign-in loads',
    );
    expect(h.container.read(boardProvider).tables, isNotEmpty);

    await h.container
        .read(appControllerProvider.notifier)
        .logout(); // keep the tablet checked out, like "Sign out (keep tablet)"
    await settle(tester);
    await loginWith(tester, 'amaka', '1234');
    await settle(tester);

    final board = h.container.read(boardProvider);
    expect(board.loading, isFalse, reason: 'no endless spinner');
    expect(board.loaded, isTrue);
    expect(board.tables, isNotEmpty, reason: 'tables are shown again');
  });

  testWidgets('board loads after "Return tablet" and checking out again', (
    tester,
  ) async {
    final h = Harness();
    await h.pump(tester);
    await enrolAs(tester, 'ATT-2026');
    await loginWith(tester, 'amaka', '1234');
    await tester.tap(find.byKey(const Key('facility-f-restaurant')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('checkout-submit')));
    await settle(tester);
    expect(h.container.read(boardProvider).loaded, isTrue);

    await h.container
        .read(appControllerProvider.notifier)
        .checkinTablet(); // "Return tablet (end of shift)"
    await settle(tester);
    await loginWith(tester, 'amaka', '1234');
    await tester.tap(find.byKey(const Key('facility-f-restaurant')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('checkout-submit')));
    await settle(tester);

    final board = h.container.read(boardProvider);
    expect(board.facilityId, 'f-restaurant');
    expect(board.loading, isFalse, reason: 'no endless spinner');
    expect(board.loaded, isTrue);
    expect(board.tables, isNotEmpty);
  });
}
