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
import '../../core/state/order_service.dart';
import '../../core/state/outbox.dart';
import '../shared/widgets.dart';
import 'bill_panel.dart';

/// Orders of the selected table / tab with per-line preparation status and
/// the actions the signed-in staff is allowed to attempt.
class OrderPane extends ConsumerWidget {
  const OrderPane({super.key, required this.selection});
  final Selection selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(boardProvider);
    final staff = ref.watch(appControllerProvider.select((s) => s.staff));
    final pendingIds = ref.watch(outboxProvider).pendingOrderIds;
    final table = board.tables
        .where((t) => t.id == selection.tableId)
        .firstOrNull;
    final tab = board.tabs.where((t) => t.id == selection.tabId).firstOrNull;
    final server = board.orders.where(selection.matches).toList();
    final serverIds = server.map((o) => o.id).toSet();
    // Orders queued offline (not yet on the server) for this selection.
    final queued = ref
        .watch(pendingOrdersProvider)
        .where((o) => !serverIds.contains(o.id) && selection.matches(o))
        .toList();
    final title =
        table?.name ??
        tab?.customerName ??
        selection.customerName ??
        'Customer';
    final canOrder = staff?.can('order.create') ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              if (table != null && table.isFree && canOrder)
                OutlinedButton.icon(
                  key: const Key('open-table'),
                  onPressed: () => _openTable(context, ref, table),
                  icon: const Icon(Icons.event_seat_outlined),
                  label: const Text('Open table'),
                ),
              const SizedBox(width: 12),
              FilledButton.icon(
                key: const Key('add-order'),
                onPressed: canOrder
                    ? () {
                        ref.read(selectionProvider.notifier).select(selection);
                        unawaited(context.push(Routes.menu));
                      }
                    : null,
                icon: const Icon(Icons.add_shopping_cart),
                label: Text(
                  server.isEmpty && queued.isEmpty
                      ? 'Take order'
                      : 'Add order to tab',
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: (server.isEmpty && queued.isEmpty)
              ? const EmptyState(
                  Icons.receipt_long_outlined,
                  'No open orders here yet',
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final o in queued)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: OrderCard(order: o, pending: true),
                      ),
                    for (final o in server)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: OrderCard(
                          order: o,
                          pending: pendingIds.contains(o.id),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _openTable(
    BuildContext context,
    WidgetRef ref,
    TableInfo t,
  ) async {
    try {
      await ref.read(apiProvider).openTable(t.id, idempotencyKey: newId());
      await ref.read(boardProvider.notifier).refresh(silent: true);
      if (context.mounted) toast(context, '${t.name} opened');
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e), error: true);
    }
  }
}

class OrderCard extends ConsumerStatefulWidget {
  const OrderCard({super.key, required this.order, this.pending = false});
  final Order order;
  final bool pending;
  @override
  ConsumerState<OrderCard> createState() => OrderCardState();
}

class OrderCardState extends ConsumerState<OrderCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _serve() => _run(() async {
    await ref.read(orderServiceProvider).markServed(widget.order.id);
    await ref.read(boardProvider.notifier).refresh(silent: true);
    if (mounted) toast(context, 'Marked served');
  });

  /// Runs a sensitive action. Holders of the execute permission call directly
  /// (the server may answer 202 = awaiting supervisor). Others authorise with
  /// a supervisor PIN step-up (contract flow A2 step 3b).
  Future<void> _sensitive(
    String approvePermission,
    String title,
    Future<SensitiveResult> Function(String? stepUpToken) call, {
    required bool canExecute,
  }) async {
    String? token;
    if (!canExecute) {
      final creds = await askStepUp(
        context,
        title: '$title - supervisor authorisation',
      );
      if (creds == null || !mounted) return;
      try {
        final s = await ref
            .read(orderServiceProvider)
            .stepUp(
              identifier: creds.identifier,
              secret: creds.secret,
              credentialType: creds.credentialType,
              permission: approvePermission,
              entityId: widget.order.id,
            );
        token = s.token;
      } on Object catch (e) {
        if (mounted) toast(context, describeError(e), error: true);
        return;
      }
    }
    await _run(() async {
      final r = await call(token);
      await ref.read(boardProvider.notifier).refresh(silent: true);
      if (!mounted) return;
      toast(
        context,
        r.isPending ? 'Sent to a supervisor for approval' : '$title done',
      );
    });
  }

  Future<void> _void() async {
    final reason = await askReason(
      context,
      title: 'Void order ${widget.order.number ?? ''}',
      confirm: 'Void order',
    );
    if (reason == null || !mounted) return;
    final can = ref.read(appControllerProvider).can('order.void.execute');
    await _sensitive(
      'order.void.approve',
      'Void',
      (t) => ref
          .read(orderServiceProvider)
          .voidOrder(widget.order.id, reason: reason, stepUpToken: t),
      canExecute: can,
    );
  }

  Future<void> _adjust(OrderLine line) async {
    final r = await showDialog<_AdjustChoice>(
      context: context,
      builder: (_) => _AdjustDialog(line: line),
    );
    if (r == null || !mounted) return;
    final can = ref.read(appControllerProvider).can('order.discount.execute');
    final perm = switch (r.kind) {
      'COMP' => 'order.comp.approve',
      'PRICE_OVERRIDE' => 'order.price_override.approve',
      _ => 'order.discount.approve',
    };
    await _sensitive(
      perm,
      r.kind == 'COMP' ? 'Comp' : 'Adjustment',
      (t) => ref
          .read(orderServiceProvider)
          .adjust(
            widget.order.id,
            line.id,
            kind: r.kind,
            value: r.value,
            reason: r.reason,
            stepUpToken: t,
          ),
      canExecute: can,
    );
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    final staff = ref.watch(appControllerProvider.select((s) => s.staff));
    final estimated = widget.pending && o.total == null;
    final canServe =
        !widget.pending && o.hasReady && (staff?.can('order.serve') ?? true);
    final sent = o.status != OrderStatus.draft && !widget.pending;
    // A printed bill freezes the order (server: 409 order_billed).
    final frozen = o.bill.printed;
    return Card(
      key: Key('order-${o.id}'),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  o.number ?? 'New order',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(width: 12),
                OrderStatusPill(
                  widget.pending ? o.copyWith(pendingConfirmation: true) : o,
                ),
                const Spacer(),
                if (o.total != null)
                  Text(
                    money(o.total),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                if (estimated)
                  const Text(
                    'total confirmed by server',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
              ],
            ),
            if (widget.pending)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Waiting for the connection. This order is saved on the tablet and will be sent automatically.',
                  style: TextStyle(
                    color: R007Colors.orange,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (o.awaitingApproval)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Waiting for a supervisor to approve.',
                  style: TextStyle(
                    color: R007Colors.purple,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            const Divider(),
            for (final l in o.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 40,
                      child: Text(
                        '${l.quantity}x',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l.name,
                            style: TextStyle(
                              fontSize: 18,
                              decoration: l.isVoided
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                          if (l.notes != null && l.notes!.isNotEmpty)
                            Text(
                              l.notes!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (!widget.pending)
                      StatusPill(
                        statusLabel(l.status),
                        lineStatusColor(l.status),
                      ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 96,
                      child: Text(
                        money(l.lineTotal),
                        textAlign: TextAlign.right,
                      ),
                    ),
                    if (sent && !l.isVoided && !o.awaitingApproval && !frozen)
                      PopupMenuButton<String>(
                        key: Key('line-menu-${l.id}'),
                        icon: const Icon(Icons.more_vert),
                        onSelected: (_) => _adjust(l),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'adjust',
                            child: Text(
                              (staff?.can('order.discount.execute') ?? false)
                                  ? 'Discount / comp...'
                                  : 'Discount / comp (supervisor)...',
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            if (sent &&
                o.isOpen &&
                !o.awaitingApproval &&
                !o.pendingConfirmation)
              BillPanel(order: o),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (sent && o.isOpen && !o.awaitingApproval && !frozen)
                  TextButton.icon(
                    key: Key('void-${o.id}'),
                    onPressed: _busy ? null : _void,
                    icon: const Icon(Icons.block, color: R007Colors.red),
                    label: Text(
                      (staff?.can('order.void.execute') ?? false)
                          ? 'Void order'
                          : 'Void (supervisor)',
                      style: const TextStyle(color: R007Colors.red),
                    ),
                  ),
                const SizedBox(width: 8),
                if (canServe)
                  FilledButton.icon(
                    key: Key('serve-${o.id}'),
                    onPressed: _busy ? null : _serve,
                    icon: const Icon(Icons.room_service),
                    label: const Text('Mark served'),
                    style: FilledButton.styleFrom(
                      backgroundColor: R007Colors.green,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AdjustChoice {
  const _AdjustChoice(this.kind, this.value, this.reason);
  final String kind;
  final String? value;
  final String reason;
}

class _AdjustDialog extends StatefulWidget {
  const _AdjustDialog({required this.line});
  final OrderLine line;
  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  String _kind = 'DISCOUNT_PERCENT';
  final _value = TextEditingController(text: '10');
  final _reason = TextEditingController();
  String? _err;

  @override
  Widget build(BuildContext context) {
    final needsValue = _kind != 'COMP';
    return AlertDialog(
      title: Text('Adjust ${widget.line.name}'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              key: const Key('adjust-kind'),
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Type'),
              items: const [
                DropdownMenuItem(
                  value: 'DISCOUNT_PERCENT',
                  child: Text('Discount %'),
                ),
                DropdownMenuItem(
                  value: 'DISCOUNT_AMOUNT',
                  child: Text('Discount amount'),
                ),
                DropdownMenuItem(
                  value: 'PRICE_OVERRIDE',
                  child: Text('Price override'),
                ),
                DropdownMenuItem(
                  value: 'COMP',
                  child: Text('Complimentary (comp)'),
                ),
              ],
              onChanged: (v) => setState(() {
                _kind = v ?? _kind;
                _value.text = _kind == 'DISCOUNT_PERCENT' ? '10' : '';
              }),
            ),
            if (needsValue) ...[
              const SizedBox(height: 12),
              TextField(
                key: const Key('adjust-value'),
                controller: _value,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: _kind == 'DISCOUNT_PERCENT'
                      ? 'Percent'
                      : 'Amount (NGN)',
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const Key('adjust-reason'),
              controller: _reason,
              decoration: const InputDecoration(labelText: 'Reason (required)'),
            ),
            if (_err != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _err!,
                  style: const TextStyle(color: R007Colors.red),
                ),
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
          key: const Key('adjust-confirm'),
          onPressed: () {
            if (_reason.text.trim().length < 3) {
              setState(() => _err = 'A reason is required');
              return;
            }
            if (needsValue && _value.text.trim().isEmpty) {
              setState(() => _err = 'Enter a value');
              return;
            }
            Navigator.of(context).pop(
              _AdjustChoice(
                _kind,
                needsValue ? _value.text.trim() : null,
                _reason.text.trim(),
              ),
            );
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
