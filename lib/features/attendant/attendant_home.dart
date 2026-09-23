import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/models/models.dart';
import '../../core/state/app_state.dart';
import '../../core/state/attendant_state.dart';
import '../../core/state/board.dart';
import '../../core/state/outbox.dart';
import '../shared/widgets.dart';
import 'order_pane.dart';

/// Attendant mode: live tables/customers of the checked-out facility on the
/// left, the selected table/tab with its orders on the right.
class AttendantHome extends ConsumerWidget {
  const AttendantHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    final board = ref.watch(boardProvider);
    final selection = ref.watch(selectionProvider);
    final canOrder = app.can('order.create');

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${app.facilityName ?? 'Attendant'}  -  ${app.staff?.name ?? ''}',
        ),
        actions: [
          if (board.stale)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: StatusPill(
                'LAST KNOWN DATA',
                R007Colors.orange,
                icon: Icons.history,
              ),
            ),
          IconButton(
            key: const Key('refresh'),
            tooltip: 'Refresh',
            icon: board.loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: () => ref.read(boardProvider.notifier).refresh(),
          ),
          IconButton(
            key: const Key('lock'),
            tooltip: 'Lock tablet',
            icon: const Icon(Icons.lock_outline),
            onPressed: () => ref.read(appControllerProvider.notifier).lock(),
          ),
          PopupMenuButton<String>(
            key: const Key('menu'),
            onSelected: (v) async {
              if (v == 'return') await _returnTablet(context, ref);
              if (v == 'signout') {
                await ref.read(appControllerProvider.notifier).logout();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'return',
                child: Text('Return tablet (end of shift)'),
              ),
              PopupMenuItem(
                value: 'signout',
                child: Text('Sign out (keep tablet)'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _AlertStack(alerts: board.alerts),
          if (board.error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: InlineError(board.error!),
            ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 380, child: _LeftPane(canOrder: canOrder)),
                const VerticalDivider(width: 1),
                Expanded(
                  child: selection == null
                      ? const EmptyState(
                          Icons.touch_app_outlined,
                          'Select a table or customer\nto see and add orders',
                        )
                      : OrderPane(selection: selection),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _returnTablet(BuildContext context, WidgetRef ref) async {
    final pending = ref.read(outboxProvider).pending.length;
    if (pending > 0) {
      toast(
        context,
        '$pending unsent action(s). Reconnect and let them send before ending your shift.',
        error: true,
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Return this tablet?'),
        content: const Text(
          'This ends your shift on this tablet and signs you out. Make sure every order has been sent.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('return-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Return tablet'),
          ),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    try {
      await ref.read(appControllerProvider.notifier).checkinTablet();
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e), error: true);
    }
  }
}

class _AlertStack extends ConsumerWidget {
  const _AlertStack({required this.alerts});
  final List<AppAlert> alerts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (alerts.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final a in alerts)
          Material(
            key: Key('alert-${a.id}'),
            color: a.kind == 'ready' ? R007Colors.green : R007Colors.purple,
            child: ListTile(
              leading: Icon(
                a.kind == 'ready' ? Icons.notifications_active : Icons.gavel,
                color: Colors.white,
              ),
              title: Text(
                a.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
              subtitle: a.body == null
                  ? null
                  : Text(a.body!, style: const TextStyle(color: Colors.white)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (a.orderId != null)
                    TextButton(
                      onPressed: () {
                        final o = ref.read(boardProvider).orderById(a.orderId!);
                        if (o != null) {
                          ref
                              .read(selectionProvider.notifier)
                              .select(
                                Selection(tableId: o.tableId, tabId: o.tabId),
                              );
                        }
                        ref.read(boardProvider.notifier).dismissAlert(a.id);
                      },
                      child: const Text(
                        'View',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () =>
                        ref.read(boardProvider.notifier).dismissAlert(a.id),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _LeftPane extends ConsumerWidget {
  const _LeftPane({required this.canOrder});
  final bool canOrder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(boardProvider);
    final selection = ref.watch(selectionProvider);
    final pendingIds = ref.watch(outboxProvider).pendingOrderIds;
    // Customers = open tabs that are not attached to a table.
    final customers = board.tabs.where((t) => t.tableId == null).toList();

    Widget tableTile(TableInfo t) {
      final orders = board.ordersForTable(t.id);
      final ready = orders.where((o) => o.status == OrderStatus.ready).length;
      final busy = !t.isFree;
      final sel = selection?.tableId == t.id;
      return InkWell(
        key: Key('table-${t.id}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => ref
            .read(selectionProvider.notifier)
            .select(Selection(tableId: t.id, tabId: t.tabId)),
        child: Container(
          width: 108,
          height: 88,
          decoration: BoxDecoration(
            color: ready > 0
                ? R007Colors.green
                : busy
                ? Theme.of(context).colorScheme.tertiaryContainer
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: sel
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 3,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                t.name,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: ready > 0 ? Colors.white : null,
                ),
              ),
              Text(
                ready > 0
                    ? 'READY x$ready'
                    : busy
                    ? '${orders.length} order${orders.length == 1 ? '' : 's'}'
                    : 'Free',
                style: TextStyle(
                  color: ready > 0 ? Colors.white : null,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (board.tables.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(
              'Tables',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final t in board.tables) tableTile(t)],
          ),
          const SizedBox(height: 16),
        ],
        Row(
          children: [
            Expanded(
              child: Text(
                'Customers / tabs',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (canOrder)
              FilledButton.tonalIcon(
                key: const Key('new-customer'),
                onPressed: () => _newCustomer(context, ref),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('New'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (customers.isEmpty &&
            ref
                .watch(pendingOrdersProvider)
                .where((o) => o.tableId == null && o.tabId != null)
                .isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('No open customer tabs'),
          ),
        for (final t in customers)
          Card(
            color: selection?.tabId == t.id
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            child: ListTile(
              key: Key('tab-${t.id}'),
              leading: const Icon(Icons.person_outline),
              title: Text(t.customerName ?? 'Tab'),
              subtitle: Text(
                '${t.orderIds.length} order(s)  -  ${money(t.total)}',
              ),
              trailing:
                  board
                      .ordersForTab(t.id)
                      .any((o) => o.status == OrderStatus.ready)
                  ? const StatusPill(
                      'READY',
                      R007Colors.green,
                      icon: Icons.notifications_active,
                    )
                  : null,
              onTap: () => ref
                  .read(selectionProvider.notifier)
                  .select(Selection(tabId: t.id, customerName: t.customerName)),
            ),
          ),
        if (pendingIds.isNotEmpty) ...[
          const SizedBox(height: 16),
          const StatusPill(
            'UNSENT ORDERS QUEUED',
            R007Colors.orange,
            icon: Icons.cloud_upload_outlined,
          ),
        ],
        if (!board.loaded &&
            board.tables.isEmpty &&
            customers.isEmpty &&
            !board.stale)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }

  Future<void> _newCustomer(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New customer tab'),
        content: SizedBox(
          width: 360,
          child: TextField(
            key: const Key('customer-name'),
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Customer name or lounger / seat',
            ),
            onSubmitted: (_) => Navigator.of(ctx).pop(c.text.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('customer-ok'),
            onPressed: () => Navigator.of(ctx).pop(c.text.trim()),
            child: const Text('Start order'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    ref
        .read(selectionProvider.notifier)
        .select(Selection(customerName: name, newCustomer: true));
    if (context.mounted) unawaited(context.push(Routes.menu));
  }
}
