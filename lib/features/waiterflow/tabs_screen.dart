import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/models/waiter_flow.dart';
import '../../core/state/app_state.dart';
import '../../core/state/board.dart';
import '../../core/state/order_service.dart';
import '../../core/state/waiter_flow_state.dart';
import '../../core/util/money.dart';
import '../shared/widgets.dart';
import 'pay_dialog.dart';

/// Waiter-only flow: every unpaid tab, select one or several, take payment on the spot (confirmed here, no cashier).
/// Supervisors/managers see everybody's tabs with the waiter's name and can take payment for them or reassign them.
class TabsScreen extends ConsumerStatefulWidget {
  const TabsScreen({super.key});
  @override
  ConsumerState<TabsScreen> createState() => TabsScreenState();
}

class TabsScreenState extends ConsumerState<TabsScreen> {
  final Set<String> _selected = {};
  String? _waiter; // staff id filter (manage view)
  bool _busy = false;
  bool _preselected = false;
  String _attemptKey = newId();

  void _select(String key, bool on) => setState(() {
    on ? _selected.add(key) : _selected.remove(key);
    _attemptKey = newId(); // a different set of tabs is a different payment
  });

  void _applyPreselect(OpenItems items) {
    if (_preselected) return;
    _preselected = true;
    final want = ref.read(preselectOrdersProvider);
    if (want.isEmpty) return;
    for (final g in items.groups) {
      if (g.allServed && !g.handoverPending && g.orderIds.any(want.contains)) {
        _selected.add(g.key);
      }
    }
    Future.microtask(
      () => ref.read(preselectOrdersProvider.notifier).set(const {}),
    );
  }

  Future<void> _reload() async {
    await ref.read(boardProvider.notifier).refresh(silent: true);
    ref.invalidate(openItemsProvider);
  }

  Future<void> _serve(TabGroup g) async {
    setState(() => _busy = true);
    try {
      for (final o in g.orders.where((o) => o.status != 'SERVED')) {
        await ref.read(orderServiceProvider).markServed(o.id);
      }
      await _reload();
      if (mounted) toast(context, 'Marked served');
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pay(List<TabGroup> chosen) async {
    if (_busy || chosen.isEmpty) return;
    final total = Money.sum(chosen.map((g) => g.balance));
    final owners = {for (final g in chosen) g.ownerStaffId: g.ownerName};
    final me = ref.read(appControllerProvider).staff?.id;
    final others = owners.entries
        .where((e) => e.key != me)
        .map((e) => e.value)
        .toSet();
    final tenders = await askPayment(
      context,
      total: total,
      tabCount: chosen.length,
      onBehalfOf: others.isEmpty ? null : others.join(', '),
    );
    if (tenders == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final facilityId = ref.read(appControllerProvider).facilityId!;
      final result = await ref
          .read(apiProvider)
          .waiterSettle(
            facilityId: facilityId,
            orderIds: [for (final g in chosen) ...g.orderIds],
            tenders: tenders,
            idempotencyKey: _attemptKey,
          );
      _attemptKey = newId();
      _selected.clear();
      await _reload();
      if (!mounted) return;
      await _paidDialog(total, result);
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _paidDialog(String total, WaiterPayResult r) => showDialog<void>(
    context: context,
    builder: (ctx) {
      var sent = false;
      return StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          icon: const Icon(
            Icons.check_circle,
            color: R007Colors.green,
            size: 56,
          ),
          title: Text('Paid ${money(total)}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Payment recorded and confirmed. The tab is closed.'),
              if (Money.toMinor(r.changeDue) > BigInt.zero)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Change to give: ${money(r.changeDue)}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            if (r.receiptId.isNotEmpty)
              OutlinedButton.icon(
                key: const Key('print-receipt'),
                onPressed: sent
                    ? null
                    : () async {
                        try {
                          await ref
                              .read(apiProvider)
                              .requestReceiptPrint(
                                r.receiptId,
                                idempotencyKey: newId(),
                              );
                          setS(() => sent = true);
                          if (ctx.mounted) {
                            toast(ctx, 'Receipt sent to the printer queue');
                          }
                        } on Object catch (e) {
                          if (ctx.mounted) {
                            toast(ctx, describeError(e), error: true);
                          }
                        }
                      },
                icon: const Icon(Icons.print_outlined),
                label: Text(
                  sent ? 'Sent to printer' : 'Send receipt to printer',
                ),
              ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    },
  );

  Future<void> _reassign(TabGroup g) async {
    final facilityId = ref.read(appControllerProvider).facilityId!;
    final r = await showDialog<({String to, String reason})>(
      context: context,
      builder: (_) => _ReassignDialog(
        label: g.label,
        facilityId: facilityId,
        from: g.ownerName,
      ),
    );
    if (r == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(apiProvider)
          .reassignTabs(
            facilityId: facilityId,
            toStaffId: r.to,
            orderIds: g.orderIds,
            reason: r.reason,
            idempotencyKey: newId(),
          );
      await _reload();
      if (mounted) toast(context, 'Moved to the other waiter');
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(openItemsProvider);
    final app = ref.watch(appControllerProvider);
    final manage = app.can('waiterflow.manage');
    final me = app.staff?.id;

    return Scaffold(
      appBar: AppBar(
        title: Text(manage ? 'Open tabs and payment' : 'My tabs and payment'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(openItemsProvider),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: InlineError(describeError(e)),
        ),
        data: (items) {
          _applyPreselect(items);
          final groups = items.groups
              .where((g) => _waiter == null || g.ownerStaffId == _waiter)
              .toList();
          final chosen = [
            for (final g in items.groups)
              if (_selected.contains(g.key)) g,
          ];
          final total = Money.sum(chosen.map((g) => g.balance));
          return Column(
            children: [
              if (items.all && items.waiters.isNotEmpty)
                SizedBox(
                  height: 56,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text('Everyone  ${money(items.balance)}'),
                          selected: _waiter == null,
                          onSelected: (_) => setState(() => _waiter = null),
                        ),
                      ),
                      for (final w in items.waiters)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text('${w.name}  ${money(w.balance)}'),
                            selected: _waiter == w.staffId,
                            onSelected: (_) =>
                                setState(() => _waiter = w.staffId),
                          ),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: groups.isEmpty
                    ? const EmptyState(
                        Icons.check_circle_outline,
                        'Nothing is owed. Every tab is paid.',
                      )
                    : RefreshIndicator(
                        onRefresh: _reload,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: groups.length,
                          itemBuilder: (_, i) {
                            final g = groups[i];
                            return _GroupCard(
                              group: g,
                              mine: g.ownerStaffId == me,
                              showOwner: items.all,
                              selected: _selected.contains(g.key),
                              busy: _busy,
                              canManage: manage,
                              onSelect: (v) => _select(g.key, v),
                              onServe: () => _serve(g),
                              onReassign: () => _reassign(g),
                              onPayOne: () => _pay([g]),
                            );
                          },
                        ),
                      ),
              ),
              SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    boxShadow: const [
                      BoxShadow(blurRadius: 6, color: Color(0x22000000)),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          chosen.isEmpty
                              ? 'Tick the tabs the customer is paying for'
                              : '${chosen.length} tab${chosen.length == 1 ? '' : 's'}  -  ${money(total)}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          _selected
                            ..clear()
                            ..addAll([
                              for (final g in groups)
                                if (g.allServed && !g.handoverPending) g.key,
                            ]);
                          _attemptKey = newId();
                        }),
                        child: const Text('Select all served'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        key: const Key('take-payment'),
                        onPressed: chosen.isEmpty || _busy
                            ? null
                            : () => _pay(chosen),
                        icon: const Icon(Icons.payments_outlined),
                        label: const Text('Take payment'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.group,
    required this.mine,
    required this.showOwner,
    required this.selected,
    required this.busy,
    required this.canManage,
    required this.onSelect,
    required this.onServe,
    required this.onReassign,
    required this.onPayOne,
  });
  final TabGroup group;
  final bool mine;
  final bool showOwner;
  final bool selected;
  final bool busy;
  final bool canManage;
  final void Function(bool) onSelect;
  final VoidCallback onServe;
  final VoidCallback onReassign;
  final VoidCallback onPayOne;

  @override
  Widget build(BuildContext context) {
    final g = group;
    final payable = g.allServed && !g.handoverPending;
    return Card(
      key: Key('tab-${g.key}'),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              key: Key('tab-check-${g.key}'),
              value: selected,
              onChanged: payable ? (v) => onSelect(v ?? false) : null,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 10,
                    children: [
                      Text(
                        g.label,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if (g.handoverPending)
                        const StatusPill(
                          'HAND-OVER PENDING',
                          R007Colors.orange,
                          icon: Icons.swap_horiz,
                        )
                      else if (g.allServed)
                        const StatusPill('SERVED', R007Colors.greenDark)
                      else
                        const StatusPill('NOT SERVED YET', R007Colors.blue),
                    ],
                  ),
                  if (showOwner || !mine)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        mine ? 'Yours' : 'Waiter: ${g.ownerName}',
                        style: TextStyle(
                          color: mine
                              ? R007Colors.greenDark
                              : R007Colors.purple,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  for (final o in g.orders)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        g.label == o.number
                            ? o.lines.join(', ')
                            : '${o.number}:  ${o.lines.join(', ')}',
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  money(g.balance),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                if (!g.allServed)
                  OutlinedButton.icon(
                    key: Key('serve-${g.key}'),
                    onPressed: busy ? null : onServe,
                    icon: const Icon(Icons.room_service),
                    label: const Text('Mark served'),
                  )
                else if (payable)
                  FilledButton(
                    key: Key('pay-${g.key}'),
                    onPressed: busy ? null : onPayOne,
                    child: Text(mine ? 'Pay' : 'Pay for waiter'),
                  ),
                if (canManage && !g.handoverPending)
                  TextButton(
                    key: Key('reassign-${g.key}'),
                    onPressed: busy ? null : onReassign,
                    child: const Text('Move to another waiter'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReassignDialog extends ConsumerStatefulWidget {
  const _ReassignDialog({
    required this.label,
    required this.facilityId,
    required this.from,
  });
  final String label;
  final String facilityId;
  final String from;
  @override
  ConsumerState<_ReassignDialog> createState() => _ReassignDialogState();
}

class _ReassignDialogState extends ConsumerState<_ReassignDialog> {
  List<Colleague>? _colleagues;
  String? _to;
  final _reason = TextEditingController();
  String? _err;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final c = await ref.read(apiProvider).waiterColleagues(widget.facilityId);
      if (mounted) setState(() => _colleagues = c);
    } on Object catch (e) {
      if (mounted) setState(() => _err = describeError(e));
    }
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Move ${widget.label}'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Currently with ${widget.from}. It moves at once and is recorded with your reason.',
          ),
          const SizedBox(height: 12),
          if (_colleagues == null && _err == null)
            const LinearProgressIndicator()
          else
            DropdownButtonFormField<String>(
              key: const Key('reassign-to'),
              initialValue: _to,
              decoration: const InputDecoration(labelText: 'New waiter'),
              items: [
                for (final c in _colleagues ?? const <Colleague>[])
                  DropdownMenuItem(value: c.staffId, child: Text(c.name)),
              ],
              onChanged: (v) => setState(() => _to = v),
            ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('reassign-reason'),
            controller: _reason,
            decoration: const InputDecoration(labelText: 'Reason (required)'),
          ),
          if (_err != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_err!, style: const TextStyle(color: R007Colors.red)),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('reassign-confirm'),
        onPressed: () {
          if (_to == null) {
            return setState(() => _err = 'Choose the new waiter');
          }
          if (_reason.text.trim().length < 3) {
            return setState(() => _err = 'A reason is required');
          }
          Navigator.of(context).pop((to: _to!, reason: _reason.text.trim()));
        },
        child: const Text('Move'),
      ),
    ],
  );
}
