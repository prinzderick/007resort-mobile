import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/r007_api.dart';
import '../device/device_mode.dart';
import '../models/models.dart';
import '../offline/offline_queue.dart';
import '../util/money.dart';
import 'app_state.dart';
import 'connectivity.dart';
import 'outbox.dart';

class AppAlert {
  const AppAlert({
    required this.id,
    required this.kind,
    required this.title,
    this.body,
    this.orderId,
  });
  final String id;

  /// `ready` | `approval` | `bill` | `paid` | `rejected` | `info`
  final String kind;
  final String title;
  final String? body;
  final String? orderId;
}

class BoardState {
  const BoardState({
    this.facilityId,
    this.tables = const [],
    this.orders = const [],
    this.tabs = const [],
    this.loading = false,
    this.loaded = false,
    this.error,
    this.stale = false,
    this.lastSync,
    this.alerts = const [],
    this.revision = 0,
  });

  final String? facilityId;
  final List<TableInfo> tables;
  final List<Order> orders;
  final List<TabInfo> tabs;
  final bool loading;
  final bool loaded;
  final String? error;

  /// True when the last refresh failed because the server is unreachable:
  /// the data shown is the last known state.
  final bool stale;
  final DateTime? lastSync;
  final List<AppAlert> alerts;

  /// Incremented on every refresh/event; other controllers refresh on change.
  final int revision;

  BoardState copyWith({
    List<TableInfo>? tables,
    List<Order>? orders,
    List<TabInfo>? tabs,
    bool? loading,
    bool? loaded,
    String? error,
    bool clearError = false,
    bool? stale,
    DateTime? lastSync,
    List<AppAlert>? alerts,
    int? revision,
  }) => BoardState(
    facilityId: facilityId,
    tables: tables ?? this.tables,
    orders: orders ?? this.orders,
    tabs: tabs ?? this.tabs,
    loading: loading ?? this.loading,
    loaded: loaded ?? this.loaded,
    error: clearError ? null : (error ?? this.error),
    stale: stale ?? this.stale,
    lastSync: lastSync ?? this.lastSync,
    alerts: alerts ?? this.alerts,
    revision: revision ?? this.revision,
  );

  Order? orderById(String id) => orders.where((o) => o.id == id).firstOrNull;
  List<Order> ordersForTable(String tableId) =>
      orders.where((o) => o.tableId == tableId).toList();
  List<Order> ordersForTab(String tabId) =>
      orders.where((o) => o.tabId == tabId).toList();
}

final boardProvider = NotifierProvider<BoardController, BoardState>(
  BoardController.new,
);

/// Live view of one facility: tables, open tabs and orders (with per-line
/// preparation status). REST is the authority; realtime events and a 10 s
/// poll only tell it when to reload (realtime.md: "hint channel").
class BoardController extends Notifier<BoardState> {
  StreamSubscription<RealtimeEvent>? _rt;
  StreamSubscription<QueuedOp>? _conf;
  Timer? _poll;
  Timer? _debounce;
  final Set<String> _readyAlerted = {};
  bool _disposed = false;

  @override
  BoardState build() {
    final facilityId = ref.watch(
      appControllerProvider.select((s) => s.facilityId),
    );
    final hasSession = ref.watch(
      appControllerProvider.select((s) => s.session != null),
    );
    ref.onDispose(() {
      _disposed = true;
      _poll?.cancel();
      _debounce?.cancel();
      unawaited(_rt?.cancel());
      unawaited(_conf?.cancel());
    });
    if (facilityId == null || !hasSession) return const BoardState();
    scheduleMicrotask(() => _start(facilityId));
    return BoardState(facilityId: facilityId, loading: true);
  }

  void _start(String facilityId) {
    if (_disposed) return;
    unawaited(refresh());
    final deviceId = ref.read(appControllerProvider).device?.deviceId;
    final api = ref.read(apiProvider);
    if (deviceId != null) {
      _rt = api
          .realtime(facilityId: facilityId, deviceId: deviceId)
          .listen(_onEvent, onError: (Object _) {}, cancelOnError: false);
    }
    _conf = ref
        .read(outboxProvider.notifier)
        .confirmed
        .listen((_) => _scheduleRefresh());
    if (ref.read(timersEnabledProvider)) {
      _poll = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(refresh(silent: true)),
      );
    }
  }

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(refresh(silent: true)),
    );
  }

  void _onEvent(RealtimeEvent e) {
    final me = ref.read(appControllerProvider).staff;
    switch (e.name) {
      case 'order.ready':
        final waiter = e.data['waiterStaffId']?.toString();
        if (waiter == null || waiter == me?.id) {
          _pushAlert(
            AppAlert(
              id: 'ready-${e.data['orderId']}',
              kind: 'ready',
              title: 'Order ready to serve',
              body:
                  '${e.data['orderNumber'] ?? ''} ${e.data['tableLabel'] ?? ''}'
                      .trim(),
              orderId: e.data['orderId']?.toString(),
            ),
          );
        }
      case 'approval.decided':
        final a = e.data['approval'];
        final st = a is Map ? a['status']?.toString() : null;
        _pushAlert(
          AppAlert(
            id: 'appr-${a is Map ? a['id'] : e.eventId}-$st',
            kind: 'approval',
            title: st == 'APPROVED'
                ? 'Supervisor approved your request'
                : 'Supervisor rejected your request',
            orderId: e.data['orderId']?.toString(),
          ),
        );
      case 'bill.printed':
        final o = e.data['order'];
        final ob = o is Map ? o : const <String, dynamic>{};
        final waiter = ob['createdByStaffId']?.toString();
        if (waiter == null || waiter == me?.id) {
          _pushAlert(
            AppAlert(
              id: 'bill-${ob['id']}',
              kind: 'bill',
              title: 'Bill printed - collect payment',
              body: '${ob['number'] ?? ''} ${ob['tableLabel'] ?? ''}'.trim(),
              orderId: ob['id']?.toString(),
            ),
          );
        }
      case 'payment.confirmed':
      case 'payment.rejected':
      case 'payment.expired':
        final p = e.data['payment'];
        final pb = p is Map ? p : const <String, dynamic>{};
        final by = pb['takenByStaffId']?.toString();
        if (by == null || by == me?.id) {
          final ok = e.name == 'payment.confirmed';
          final expired = e.name == 'payment.expired';
          final orderId = e.data['orderId']?.toString();
          final number = orderId == null
              ? null
              : state.orderById(orderId)?.number;
          final col = pb['collection'];
          final reason =
              e.data['reason'] ?? (col is Map ? col['decisionReason'] : null);
          _pushAlert(
            AppAlert(
              id: '${ok ? 'paid' : (expired ? 'exp' : 'rej')}-${pb['id'] ?? e.eventId}',
              kind: ok ? 'paid' : 'rejected',
              title: ok
                  ? 'Payment confirmed'
                  : expired
                  ? 'Collection expired - nobody confirmed it'
                  : 'Payment rejected by the cashier',
              body: [
                number,
                if (pb['amount'] != null) Money.format(pb['amount'].toString()),
                if (!ok) reason,
              ].where((x) => x != null && '$x'.isNotEmpty).join(' - '),
              orderId: orderId,
            ),
          );
        }
      case 'approval.requested':
        if ((me?.permissions.any((p) => p.endsWith('.approve')) ?? false)) {
          _pushAlert(
            const AppAlert(
              id: 'approval-new',
              kind: 'approval',
              title: 'New approval request',
            ),
          );
        }
    }
    _scheduleRefresh();
  }

  void _pushAlert(AppAlert a) {
    if (a.kind == 'ready' && !_readyAlerted.add(a.orderId ?? a.id)) return;
    if (state.alerts.any((x) => x.id == a.id)) return;
    state = state.copyWith(alerts: [...state.alerts, a]);
    if (ref.read(feedbackEnabledProvider)) {
      unawaited(HapticFeedback.heavyImpact());
      unawaited(SystemSound.play(SystemSoundType.alert));
    }
  }

  void dismissAlert(String id) => state = state.copyWith(
    alerts: state.alerts.where((a) => a.id != id).toList(),
  );

  /// Reloads everything for the facility over REST.
  Future<void> refresh({bool silent = false}) async {
    final facilityId = state.facilityId;
    if (facilityId == null || _disposed) return;
    if (!silent) state = state.copyWith(loading: true);
    final api = ref.read(apiProvider);
    final conn = ref.read(connectivityProvider.notifier);
    final mode = ref.read(appControllerProvider).mode;
    try {
      // Tables/tabs are secondary: a missing permission must not blank the board.
      Future<List<T>> soft<T>(Future<List<T>> f) => f.catchError((Object e) {
        if (e is ApiProblem && e.status != 401) return <T>[];
        throw e;
      });
      final withTables =
          mode == DeviceMode.attendant || mode == DeviceMode.supervisor;
      final results = await Future.wait<Object>([
        api.listOrders(facilityId),
        if (withTables)
          soft(api.listTables(facilityId))
        else
          Future.value(<TableInfo>[]),
        if (withTables)
          soft(api.listTabs(facilityId))
        else
          Future.value(<TabInfo>[]),
      ]);
      if (_disposed) return;
      final tables = results[1] as List<TableInfo>;
      final labels = {for (final t in tables) t.id: t.name};
      final orders = [
        for (final o in results[0] as List<Order>)
          o.tableId != null && o.tableLabel == null
              ? o.copyWith(tableLabel: labels[o.tableId])
              : o,
      ];
      _detectReady(orders);
      _detectBillPrinted(orders);
      // A "ready" alert is stale once the order was served, settled or voided.
      final stillReady = {
        for (final o in orders)
          if (o.hasReady && o.isOpen && o.status != OrderStatus.served) o.id,
      };
      final alerts = [
        for (final a in state.alerts)
          if (a.kind != 'ready' ||
              a.orderId == null ||
              stillReady.contains(a.orderId))
            a,
      ];
      state = state.copyWith(
        alerts: alerts,
        orders: orders,
        tables: tables,
        tabs: results[2] as List<TabInfo>,
        loading: false,
        loaded: true,
        stale: false,
        clearError: true,
        lastSync: DateTime.now().toUtc(),
        revision: state.revision + 1,
      );
      conn.reportOnline();
    } on ApiOfflineException {
      if (_disposed) return;
      conn.reportOffline();
      state = state.copyWith(loading: false, loaded: state.loaded, stale: true);
    } on ApiProblem catch (e) {
      if (_disposed) return;
      state = state.copyWith(loading: false, error: e.message);
      if (e.isUnauthorized) {
        unawaited(ref.read(appControllerProvider.notifier).logout());
      }
    }
  }

  /// Polling fallback for "bill printed" when realtime is not delivering.
  void _detectBillPrinted(List<Order> next) {
    final me = ref.read(appControllerProvider).staff;
    if (ref.read(appControllerProvider).mode != DeviceMode.attendant) return;
    final before = {for (final o in state.orders) o.id: o.bill.printed};
    for (final o in next) {
      if (o.bill.printed &&
          before[o.id] == false &&
          state.loaded &&
          (o.createdByStaffId == null || o.createdByStaffId == me?.id)) {
        _pushAlert(
          AppAlert(
            id: 'bill-${o.id}',
            kind: 'bill',
            title: 'Bill printed - collect payment',
            body: '${o.number ?? ''} ${o.tableLabel ?? ''}'.trim(),
            orderId: o.id,
          ),
        );
      }
    }
  }

  /// Polling fallback for READY notifications when realtime is not delivering.
  void _detectReady(List<Order> next) {
    final me = ref.read(appControllerProvider).staff;
    if (ref.read(appControllerProvider).mode != DeviceMode.attendant) return;
    final before = {for (final o in state.orders) o.id: o.status};
    for (final o in next) {
      final wasReady = before[o.id] == OrderStatus.ready;
      if (o.status == OrderStatus.ready &&
          !wasReady &&
          state.loaded &&
          (o.createdByStaffId == null || o.createdByStaffId == me?.id)) {
        _pushAlert(
          AppAlert(
            id: 'ready-${o.id}',
            kind: 'ready',
            title: 'Order ready to serve',
            body: '${o.number ?? ''} ${o.tableLabel ?? ''}'.trim(),
            orderId: o.id,
          ),
        );
      }
    }
  }
}
