import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/r007_api.dart';
import '../models/models.dart';
import '../storage/kv_store.dart';
import '../util/json.dart';
import '../util/money.dart';
import 'app_state.dart';
import 'connectivity.dart';
import 'outbox.dart';

/// What the attendant is working on: a table, an existing tab, or a brand-new
/// customer tab (bars without tables).
class Selection {
  const Selection({
    this.tableId,
    this.tabId,
    this.customerName,
    this.newCustomer = false,
  });
  final String? tableId;
  final String? tabId;
  final String? customerName;

  /// True while a new customer tab has not been created yet.
  final bool newCustomer;

  bool matches(Order o) =>
      (tableId != null && o.tableId == tableId) ||
      (tabId != null && o.tabId == tabId);
}

class SelectionController extends Notifier<Selection?> {
  @override
  Selection? build() => null;
  void select(Selection? s) => state = s;
}

final selectionProvider = NotifierProvider<SelectionController, Selection?>(
  SelectionController.new,
);

/// Catalog for the current facility. Falls back to the last cached copy when
/// the server is unreachable (browsing stays usable offline).
final catalogProvider = FutureProvider.autoDispose<Catalog>((ref) async {
  final facilityId = ref.watch(
    appControllerProvider.select((s) => s.facilityId),
  );
  if (facilityId == null) return const Catalog();
  final kv = ref.read(kvStoreProvider);
  final key = 'r007.catalog.$facilityId';
  try {
    final c = await ref.read(apiProvider).getCatalog(facilityId);
    ref.read(connectivityProvider.notifier).reportOnline();
    await kv.write(key, jsonEncode(c.toJson()));
    return c;
  } on ApiOfflineException {
    ref.read(connectivityProvider.notifier).reportOffline();
    final cached = await kv.read(key);
    if (cached != null) return Catalog.fromJson(jsonDecode(cached) as Json);
    rethrow;
  }
});

/// The last facility rules this tablet saw for the current facility (survives restarts and bad connections).
final cachedRulesProvider = FutureProvider<FacilityRules?>((ref) async {
  final facilityId = ref.watch(
    appControllerProvider.select((s) => s.facilityId),
  );
  if (facilityId == null) return null;
  final raw = await ref.read(kvStoreProvider).read('r007.rules.$facilityId');
  if (raw == null) return null;
  try {
    return FacilityRules.fromCache(jsonDecode(raw) as Json);
  } catch (_) {
    return null;
  }
});

/// Facility rules (open tabs, waiter-only flow ...). The service flow decides what the whole screen offers, so it must
/// never flip back to the standard flow just because one request was slow or failed: on ANY failure the last known rules
/// are kept (in memory and on the tablet), and the rules are re-read quietly every two minutes.
final rulesProvider = FutureProvider<FacilityRules>((ref) async {
  final facilityId = ref.watch(
    appControllerProvider.select((s) => s.facilityId),
  );
  if (facilityId == null) return const FacilityRules();
  final timer = Timer(const Duration(minutes: 2), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  final api = ref.read(apiProvider);
  return loadRulesResilient(
    () => api.getRules(facilityId),
    ref.read(kvStoreProvider),
    'r007.rules.$facilityId',
  );
});

/// Fetch the rules; remember them on success; on ANY failure (offline, server error, timeout, unreadable answer) return the
/// last remembered rules instead of the standard-flow default, so a flaky request can never switch the screen's flow.
Future<FacilityRules> loadRulesResilient(
  Future<FacilityRules> Function() fetch,
  KvStore kv,
  String key,
) async {
  try {
    final rules = await fetch().timeout(const Duration(seconds: 15));
    await kv.write(key, jsonEncode(rules.toCache()));
    return rules;
  } catch (_) {
    final raw = await kv.read(key);
    if (raw != null) {
      try {
        return FacilityRules.fromCache(jsonDecode(raw) as Json);
      } catch (_) {}
    }
    return const FacilityRules();
  }
}

/// Orders queued offline but not yet confirmed, as display-only drafts.
final pendingOrdersProvider = Provider<List<Order>>((ref) {
  final box = ref.watch(outboxProvider);
  return [
    for (final op in box.pending)
      if (op.type == 'order.create')
        OrderDraft.fromJson(op.payload).toPendingOrder(),
  ];
});

final cartProvider = NotifierProvider<CartController, List<DraftLine>>(
  CartController.new,
);

class CartController extends Notifier<List<DraftLine>> {
  @override
  List<DraftLine> build() => const [];

  void add(
    Product p, {
    List<ModifierOption> modifiers = const [],
    String? note,
  }) {
    final ids = modifiers.map((m) => m.id).toList()..sort();
    final i = state.indexWhere(
      (l) =>
          l.productId == p.id &&
          (List.of(l.modifierOptionIds)..sort()).join(',') == ids.join(',') &&
          (l.note ?? '') == (note ?? ''),
    );
    if (i >= 0) {
      _setQty(i, state[i].quantity + 1);
      return;
    }
    state = [
      ...state,
      DraftLine(
        lineId: newId(),
        productId: p.id,
        name: p.name,
        quantity: 1,
        // Display estimate only; the server re-prices every line.
        estUnitPrice: Money.sum([
          p.price,
          ...modifiers.map((m) => m.priceDelta),
        ]),
        modifierOptionIds: modifiers.map((m) => m.id).toList(),
        modifierNames: modifiers.map((m) => m.name).toList(),
        note: note,
      ),
    ];
  }

  void _setQty(int i, int q) {
    final l = state[i];
    final next = [...state];
    next[i] = DraftLine(
      lineId: l.lineId,
      productId: l.productId,
      name: l.name,
      quantity: q,
      estUnitPrice: l.estUnitPrice,
      modifierOptionIds: l.modifierOptionIds,
      modifierNames: l.modifierNames,
      note: l.note,
    );
    state = next;
  }

  void increment(String lineId) {
    final i = state.indexWhere((l) => l.lineId == lineId);
    if (i >= 0) _setQty(i, state[i].quantity + 1);
  }

  void decrement(String lineId) {
    final i = state.indexWhere((l) => l.lineId == lineId);
    if (i < 0) return;
    if (state[i].quantity <= 1) {
      remove(lineId);
    } else {
      _setQty(i, state[i].quantity - 1);
    }
  }

  void remove(String lineId) =>
      state = state.where((l) => l.lineId != lineId).toList();

  void setNote(String lineId, String? note) {
    final i = state.indexWhere((l) => l.lineId == lineId);
    if (i < 0) return;
    final l = state[i];
    final next = [...state];
    next[i] = DraftLine(
      lineId: l.lineId,
      productId: l.productId,
      name: l.name,
      quantity: l.quantity,
      estUnitPrice: l.estUnitPrice,
      modifierOptionIds: l.modifierOptionIds,
      modifierNames: l.modifierNames,
      note: (note == null || note.trim().isEmpty) ? null : note.trim(),
    );
    state = next;
  }

  void clear() => state = const [];

  /// Display-only estimate of the cart total.
  String get estimate =>
      Money.sum(state.map((l) => Money.times(l.estUnitPrice, l.quantity)));
}
