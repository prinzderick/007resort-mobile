import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/waiter_flow.dart';
import 'app_state.dart';
import 'attendant_state.dart';
import 'board.dart';

/// True when the signed-in facility runs the waiter-only service flow (no KDS, no cashier): the tablet serves and takes payment.
final waiterOnlyProvider = Provider<bool>(
  (ref) => ref.watch(rulesProvider).value?.waiterOnly ?? false,
);

/// Unpaid tabs: the waiter's own, or everybody's for a supervisor/manager. Reloads whenever the board refreshes.
final openItemsProvider = FutureProvider.autoDispose<OpenItems>((ref) async {
  ref.watch(boardProvider.select((b) => b.revision));
  final facilityId = ref.watch(
    appControllerProvider.select((s) => s.facilityId),
  );
  if (facilityId == null) return const OpenItems();
  return ref.read(apiProvider).waiterOpenItems(facilityId);
});

/// Pending hand-overs addressed to me (to accept or reject).
final incomingHandoversProvider = FutureProvider.autoDispose<List<TabHandover>>(
  (ref) async {
    ref.watch(boardProvider.select((b) => b.revision));
    final facilityId = ref.watch(
      appControllerProvider.select((s) => s.facilityId),
    );
    if (facilityId == null) return const [];
    return ref
        .read(apiProvider)
        .listTabHandovers(facilityId, direction: 'incoming');
  },
);

/// Pending hand-overs I started (can be cancelled until accepted).
final outgoingHandoversProvider = FutureProvider.autoDispose<List<TabHandover>>(
  (ref) async {
    ref.watch(boardProvider.select((b) => b.revision));
    final facilityId = ref.watch(
      appControllerProvider.select((s) => s.facilityId),
    );
    if (facilityId == null) return const [];
    return ref
        .read(apiProvider)
        .listTabHandovers(facilityId, direction: 'outgoing');
  },
);

/// Orders to pre-select when the Tabs screen opens (from the "Pay" button on an order).
class PreselectOrders extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};
  void set(Set<String> ids) => state = ids;
}

final preselectOrdersProvider = NotifierProvider<PreselectOrders, Set<String>>(
  PreselectOrders.new,
);
