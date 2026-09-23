import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/models/models.dart';
import '../../core/state/app_state.dart';
import '../../core/state/approvals.dart';
import '../../core/state/board.dart';
import '../attendant/order_pane.dart';
import '../shared/widgets.dart';

/// Supervisor mode: live facility monitor, tabs, and the approvals queue
/// (approve/reject with a reason and a PIN step-up).
class SupervisorHome extends ConsumerWidget {
  const SupervisorHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    final board = ref.watch(boardProvider);
    final approvals = ref.watch(approvalsProvider);
    final canApprove =
        app.staff?.permissions.any((p) => p.endsWith('.approve')) ?? false;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            '${app.facilityName ?? 'Supervisor'}  -  ${app.staff?.name ?? ''}',
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
              icon: const Icon(Icons.refresh),
              onPressed: () {
                ref.read(boardProvider.notifier).refresh();
                ref.read(approvalsProvider.notifier).refresh();
              },
            ),
            IconButton(
              tooltip: 'Lock tablet',
              icon: const Icon(Icons.lock_outline),
              onPressed: () => ref.read(appControllerProvider.notifier).lock(),
            ),
            IconButton(
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout),
              onPressed: () =>
                  ref.read(appControllerProvider.notifier).logout(),
            ),
          ],
          bottom: TabBar(
            tabs: [
              const Tab(
                key: Key('tab-live'),
                icon: Icon(Icons.monitor_heart_outlined),
                text: 'Live orders',
              ),
              Tab(
                key: const Key('tab-approvals'),
                icon: Badge(
                  isLabelVisible: approvals.pending.isNotEmpty,
                  label: Text('${approvals.pending.length}'),
                  child: const Icon(Icons.gavel),
                ),
                text: 'Approvals',
              ),
              const Tab(
                key: Key('tab-tabs'),
                icon: Icon(Icons.table_restaurant_outlined),
                text: 'Tables & tabs',
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _LiveOrders(board: board),
            _ApprovalsQueue(state: approvals, canApprove: canApprove),
            _TablesAndTabs(board: board),
          ],
        ),
      ),
    );
  }
}

class _LiveOrders extends ConsumerStatefulWidget {
  const _LiveOrders({required this.board});
  final BoardState board;
  @override
  ConsumerState<_LiveOrders> createState() => _LiveOrdersState();
}

class _LiveOrdersState extends ConsumerState<_LiveOrders> {
  String _filter = 'ALL';

  @override
  Widget build(BuildContext context) {
    final all = widget.board.orders;
    final shown = all
        .where((o) => _filter == 'ALL' || o.status == _filter)
        .toList();
    int count(String s) => all.where((o) => o.status == s).length;
    Widget chip(String key, String label, int n) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        key: Key('filter-$key'),
        label: Text('$label ($n)', style: const TextStyle(fontSize: 16)),
        selected: _filter == key,
        onSelected: (_) => setState(() => _filter = key),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                chip('ALL', 'All', all.length),
                chip(
                  OrderStatus.inPreparation,
                  'Preparing',
                  count(OrderStatus.inPreparation) + count(OrderStatus.sent),
                ),
                chip(OrderStatus.ready, 'Ready', count(OrderStatus.ready)),
                chip(OrderStatus.served, 'Served', count(OrderStatus.served)),
                chip(
                  OrderStatus.pendingApproval,
                  'Awaiting approval',
                  count(OrderStatus.pendingApproval),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? const EmptyState(Icons.receipt_long_outlined, 'No orders match')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: shown.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    final o = shown[i];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 4),
                          child: Text(
                            [
                              if (o.tableLabel != null) o.tableLabel!,
                              if (o.customerName != null) o.customerName!,
                              if (o.createdByName != null)
                                'by ${o.createdByName}',
                            ].join('  -  '),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.outline,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        OrderCard(order: o),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ApprovalsQueue extends ConsumerWidget {
  const _ApprovalsQueue({required this.state, required this.canApprove});
  final ApprovalsState state;
  final bool canApprove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.error != null && state.pending.isEmpty) {
      return Center(
        child: InlineError(
          state.error!,
          onRetry: () => ref.read(approvalsProvider.notifier).refresh(),
        ),
      );
    }
    if (state.pending.isEmpty) {
      return EmptyState(
        state.loading ? Icons.hourglass_empty : Icons.verified_outlined,
        state.loading ? 'Loading...' : 'No approvals waiting',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: state.pending.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, i) {
        final a = state.pending[i];
        return Card(
          key: Key('approval-${a.id}'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    StatusPill(
                      a.title.toUpperCase(),
                      R007Colors.purple,
                      icon: Icons.gavel,
                    ),
                    const Spacer(),
                    if (a.amount != null)
                      Text(
                        money(a.amount),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  a.summary.isEmpty
                      ? '${a.action} on ${a.entityType}'
                      : a.summary,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Requested by ${a.requestedByName ?? 'staff'}  -  reason: ${a.reason ?? '-'}',
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      key: Key('reject-${a.id}'),
                      onPressed: canApprove
                          ? () => _decide(context, ref, a, false)
                          : null,
                      icon: const Icon(Icons.close, color: R007Colors.red),
                      label: const Text(
                        'Reject',
                        style: TextStyle(color: R007Colors.red),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      key: Key('approve-${a.id}'),
                      onPressed: canApprove
                          ? () => _decide(context, ref, a, true)
                          : null,
                      icon: const Icon(Icons.check),
                      label: const Text('Approve'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _decide(
    BuildContext context,
    WidgetRef ref,
    Approval a,
    bool approve,
  ) async {
    final note = TextEditingController();
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '${approve ? 'Approve' : 'Reject'}: ${a.summary.isEmpty ? a.title : a.summary}',
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('decision-note'),
                controller: note,
                decoration: InputDecoration(
                  labelText: approve
                      ? 'Note (optional)'
                      : 'Reason for rejecting',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('decision-pin'),
                controller: pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Your PIN',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('decision-confirm'),
            onPressed: () {
              if (pin.text.isEmpty ||
                  (!approve && note.text.trim().length < 3)) {
                return;
              }
              Navigator.of(ctx).pop(true);
            },
            child: Text(approve ? 'Approve' : 'Reject'),
          ),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    try {
      await ref
          .read(approvalsProvider.notifier)
          .decide(a, approve: approve, note: note.text.trim(), pin: pin.text);
      if (context.mounted) toast(context, approve ? 'Approved' : 'Rejected');
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e), error: true);
    }
  }
}

class _TablesAndTabs extends StatelessWidget {
  const _TablesAndTabs({required this.board});
  final BoardState board;

  @override
  Widget build(BuildContext context) {
    final busy = board.tables.where((t) => !t.isFree).toList();
    final customers = board.tabs.where((t) => t.tableId == null).toList();
    if (busy.isEmpty && customers.isEmpty) {
      return const EmptyState(
        Icons.table_restaurant_outlined,
        'No occupied tables or open tabs',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final t in busy)
          Card(
            child: ListTile(
              key: Key('sv-table-${t.id}'),
              leading: const Icon(Icons.table_restaurant),
              title: Text(t.name),
              subtitle: Text(
                '${board.ordersForTable(t.id).length} open order(s)',
              ),
              trailing:
                  board
                      .ordersForTable(t.id)
                      .any((o) => o.status == OrderStatus.ready)
                  ? const StatusPill('READY', R007Colors.green)
                  : null,
            ),
          ),
        for (final t in customers)
          Card(
            child: ListTile(
              key: Key('sv-tab-${t.id}'),
              leading: const Icon(Icons.person_outline),
              title: Text(t.customerName ?? 'Tab'),
              subtitle: Text('${t.orderIds.length} order(s)'),
              trailing: Text(
                money(t.total),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
      ],
    );
  }
}
