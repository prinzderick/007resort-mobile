import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/models/collection_models.dart';
import '../../core/models/models.dart';
import '../../core/state/app_state.dart';
import '../../core/state/board.dart';
import '../../core/state/collection_service.dart';
import '../../core/util/money.dart';
import '../collection/collection_widgets.dart';
import '../collection/take_payment_sheet.dart';
import '../shared/widgets.dart';

/// Bill + collection block of an order card: bill state, "Take payment",
/// and every collection with its status. The waiter can never settle a bill
/// here: money stays PENDING until the cashier / provider confirms.
class BillPanel extends ConsumerStatefulWidget {
  const BillPanel({super.key, required this.order});
  final Order order;

  @override
  ConsumerState<BillPanel> createState() => _BillPanelState();
}

class _BillPanelState extends ConsumerState<BillPanel> {
  bool _busy = false;

  Future<void> _printBill() async {
    if (_busy) return; // duplicate-tap safe
    setState(() => _busy = true);
    try {
      await ref.read(collectionServiceProvider).printBill(widget.order.id);
      await ref.read(boardProvider.notifier).refresh(silent: true);
      if (mounted) toast(context, 'Bill sent to the printer');
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    final staff = ref.watch(appControllerProvider.select((s) => s.staff));
    final canPrint = staff?.can('bill.print') ?? false;
    final canCollect = staff?.can('payment.collect') ?? false;
    final bill = o.bill;
    final server = canCollect
        ? ref.watch(orderCollectionsProvider(o.id)).value ?? const []
        : const <Collection>[];
    final serverIds = {for (final c in server) c.id};
    final sync = [
      for (final c in ref.watch(pendingSyncCollectionsProvider(o.id)))
        if (!serverIds.contains(c.id)) c,
    ];
    final remaining = bill.remainingAfter(sync);
    final remainingZero =
        remaining != null && Money.toMinor(remaining) == BigInt.zero;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        if (!bill.printed)
          Row(
            key: Key('bill-open-${o.id}'),
            children: [
              const Icon(Icons.receipt_long_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  canPrint
                      ? 'Bill not printed yet'
                      : 'Bill not printed yet - ask the cashier to print it',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              if (canPrint)
                OutlinedButton.icon(
                  key: Key('print-bill-${o.id}'),
                  onPressed: _busy ? null : _printBill,
                  icon: const Icon(Icons.print),
                  label: const Text('Print bill'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 52),
                  ),
                ),
            ],
          )
        else
          Container(
            key: Key('bill-printed-${o.id}'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: R007Colors.blue.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: R007Colors.blue),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.receipt_long, color: R007Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        remainingZero
                            ? 'Fully collected - waiting for the cashier to confirm'
                            : 'Bill printed, awaiting payment',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: R007Colors.blue,
                        ),
                      ),
                    ),
                    if (canCollect && !remainingZero)
                      FilledButton.icon(
                        key: Key('take-payment-${o.id}'),
                        onPressed: () => showTakePaymentSheet(context, o.id),
                        icon: const Icon(Icons.point_of_sale),
                        label: const Text('Take payment'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 56),
                          textStyle: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 32,
                  runSpacing: 8,
                  children: [
                    AmountFigure('Amount due', bill.total ?? o.total),
                    AmountFigure(
                      'Confirmed',
                      bill.confirmed,
                      color: R007Colors.green,
                    ),
                    AmountFigure(
                      'Pending cashier',
                      bill.pending,
                      color: R007Colors.orange,
                    ),
                    AmountFigure('Remaining', remaining),
                  ],
                ),
              ],
            ),
          ),
        for (final c in sync) CollectionTile(c),
        for (final c in server) CollectionTile(c),
      ],
    );
  }
}
