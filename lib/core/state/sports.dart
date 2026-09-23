import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/r007_api.dart';
import '../models/models.dart';
import 'app_state.dart';
import 'connectivity.dart';

// ---------------------------------------------------------------- entrance

class EntranceState {
  const EntranceState({
    this.busy = false,
    this.result,
    this.lastCode,
    this.connectionError,
    this.history = const [],
  });
  final bool busy;
  final RedeemResult? result;
  final String? lastCode;

  /// Set when the server could not be reached: NEVER a guessed result.
  final String? connectionError;
  final List<ScanRecord> history;
}

final entranceProvider = NotifierProvider<EntranceController, EntranceState>(
  EntranceController.new,
);

class EntranceController extends Notifier<EntranceState> {
  // Reuse the SAME Idempotency-Key when retrying the same scan after a
  // connection error, so a lost response can never double-redeem.
  String? _retryCode;
  String? _retryKey;

  @override
  EntranceState build() => const EntranceState();

  Future<void> scan(String rawCode) async {
    final code = rawCode.trim();
    if (code.isEmpty || state.busy) return;
    final facilityId = ref.read(appControllerProvider).facilityId;
    if (facilityId == null) {
      state = EntranceState(
        history: state.history,
        connectionError: 'This scanner is not assigned to a facility.',
      );
      return;
    }
    final key = (_retryCode == code && _retryKey != null)
        ? _retryKey!
        : newId();
    state = EntranceState(busy: true, lastCode: code, history: state.history);
    try {
      final r = await ref
          .read(apiProvider)
          .redeem(qrToken: code, facilityId: facilityId, idempotencyKey: key);
      _retryCode = null;
      _retryKey = null;
      ref.read(connectivityProvider.notifier).reportOnline();
      state = EntranceState(
        result: r,
        lastCode: code,
        history: [
          ScanRecord(
            code: code,
            outcome: r.outcome,
            at: DateTime.now(),
            holderName: r.holderName,
            itemName: r.itemName,
          ),
          ...state.history,
        ].take(50).toList(),
      );
    } on ApiOfflineException {
      _retryCode = code;
      _retryKey = key;
      ref.read(connectivityProvider.notifier).reportOffline();
      state = EntranceState(
        lastCode: code,
        history: state.history,
        connectionError:
            'Cannot reach the server - ticket NOT checked. Do not admit until reconnected. Scan again.',
      );
    } on ApiProblem catch (e) {
      state = EntranceState(
        lastCode: code,
        history: state.history,
        connectionError: e.message,
      );
    }
  }

  /// Back to the scanner view.
  void reset() => state = EntranceState(history: state.history);
}

// ------------------------------------------------------------------- store

class StoreState {
  const StoreState({
    this.busy = false,
    this.entitlement,
    this.error,
    this.connectionError,
    this.notice,
  });
  final bool busy;
  final Entitlement? entitlement;

  /// Server-provided problem (e.g. already released) - server truth.
  final String? error;
  final String? connectionError;
  final String? notice;
}

final storeProvider = NotifierProvider<StoreController, StoreState>(
  StoreController.new,
);

class StoreController extends Notifier<StoreState> {
  String? _lastToken;
  final Map<String, String> _keys = {};

  @override
  StoreState build() => const StoreState();

  R007Api get _api => ref.read(apiProvider);
  ConnectivityController get _conn => ref.read(connectivityProvider.notifier);

  Future<void> lookup(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) return;
    state = const StoreState(busy: true);
    try {
      final e = await _api.getEntitlementByToken(code);
      _lastToken = code;
      _conn.reportOnline();
      state = StoreState(entitlement: e);
    } on ApiOfflineException {
      _conn.reportOffline();
      state = const StoreState(
        connectionError:
            'Cannot reach the server. Nothing was released. Scan again.',
      );
    } on ApiProblem catch (e) {
      state = StoreState(
        error: e.status == 404 ? 'QR code not recognised' : e.message,
      );
    }
  }

  /// Key per (action, items) so a retry after a dropped connection is safe.
  String _key(String action, List<String> ids) =>
      _keys.putIfAbsent('$action:${(List.of(ids)..sort()).join(',')}', newId);

  Future<void> release(List<String> itemIds) => _act(
    'release',
    itemIds,
    (id, key) => _api.releaseItems(id, itemIds: itemIds, idempotencyKey: key),
  );

  Future<void> returnItems(List<String> itemIds, {String condition = 'OK'}) =>
      _act(
        'return',
        itemIds,
        (id, key) => _api.returnItems(
          id,
          itemIds: itemIds,
          condition: condition,
          idempotencyKey: key,
        ),
      );

  Future<void> _act(
    String action,
    List<String> ids,
    Future<Entitlement> Function(String id, String key) call,
  ) async {
    final current = state.entitlement;
    if (current == null || ids.isEmpty || state.busy) return;
    final key = _key(action, ids);
    state = StoreState(entitlement: current, busy: true);
    try {
      final updated = await call(current.id, key);
      _keys.remove('$action:${(List.of(ids)..sort()).join(',')}');
      _conn.reportOnline();
      state = StoreState(
        entitlement: updated,
        notice: action == 'release' ? 'Items released' : 'Return recorded',
      );
    } on ApiOfflineException {
      _conn.reportOffline();
      state = StoreState(
        entitlement: current,
        connectionError: 'Cannot reach the server. Not recorded - try again.',
      );
    } on ApiProblem catch (e) {
      // Duplicate release etc.: show the server's answer and refresh from truth.
      state = StoreState(entitlement: current, error: e.message);
      final t = _lastToken;
      if (t != null && e.isConflict) {
        try {
          final fresh = await _api.getEntitlementByToken(t);
          state = StoreState(entitlement: fresh, error: e.message);
        } on Object {
          // keep the current view
        }
      }
    }
  }

  void reset() {
    _lastToken = null;
    state = const StoreState();
  }
}
