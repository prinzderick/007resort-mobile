import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/models/models.dart';
import 'package:r007_mobile/core/state/approvals.dart';

import '../helpers/harness.dart';
import 'supervisor_flow_test.dart' show harnessWithWaiterOrder;

/// A supervisor who signs in on a waiter (Attendant) tablet must still see and decide void requests.
void main() {
  testWidgets(
    'supervisor on a waiter tablet sees the void request and approves it with a PIN',
    (tester) async {
      final h = await harnessWithWaiterOrder();
      final api = h.api;
      api.setSession(
        await api.loginStaff(
          identifier: 'amaka',
          secret: '1234',
          credentialType: 'PIN',
        ),
      );
      final r = await api.voidOrder(
        'ord-1',
        reason: 'Guest left',
        idempotencyKey: 'v1',
      );
      expect(r.isPending, isTrue);
      api.setSession(null);

      await h.pump(tester);
      await enrolAs(
        tester,
        'ATT-2026',
      ); // a WAITER tablet, not a supervisor tablet
      await loginWith(tester, 'ngozi', '9999');
      await tester.tap(find.byKey(const Key('facility-f-restaurant')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('checkout-submit')));
      await settle(tester);

      expect(
        find.byKey(const Key('approvals')),
        findsOneWidget,
        reason: 'approvers get an Approvals button on the waiter tablet',
      );
      await h.container.read(approvalsProvider.notifier).refresh();
      await settle(tester);
      expect(h.container.read(approvalsProvider).pending, hasLength(1));
      expect(
        find.text('1'),
        findsWidgets,
        reason: 'the button shows how many are waiting',
      );

      await tester.tap(find.byKey(const Key('approvals')));
      await settle(tester);
      final id = h.container.read(approvalsProvider).pending.single.id;
      expect(find.byKey(Key('approval-$id')), findsOneWidget);
      await tester.tap(find.byKey(Key('approve-$id')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('decision-pin')), '9999');
      await tester.tap(find.byKey(const Key('decision-confirm')));
      await settle(tester);

      expect(h.container.read(approvalsProvider).pending, isEmpty);
      expect((await api.getOrder('ord-1')).status, OrderStatus.voided);
    },
  );

  testWidgets('a waiter who cannot approve gets no Approvals button', (
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
    expect(find.byKey(const Key('approvals')), findsNothing);
  });
}
