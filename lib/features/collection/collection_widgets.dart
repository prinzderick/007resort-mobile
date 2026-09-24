import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/models/collection_models.dart';
import '../shared/widgets.dart';

Color collectionStatusColor(String status) => switch (status) {
  CollectionStatus.confirmed => R007Colors.green,
  CollectionStatus.rejected ||
  CollectionStatus.expired ||
  CollectionStatus.cancelled => R007Colors.red,
  CollectionStatus.awaitingPayment ||
  CollectionStatus.awaitingTerminal => R007Colors.blue,
  CollectionStatus.pendingSync => R007Colors.orange,
  _ => R007Colors.amber, // pending cashier confirmation
};

IconData collectionStatusIcon(String status) => switch (status) {
  CollectionStatus.confirmed => Icons.check_circle,
  CollectionStatus.rejected => Icons.cancel,
  CollectionStatus.expired || CollectionStatus.cancelled => Icons.timer_off,
  CollectionStatus.awaitingPayment ||
  CollectionStatus.awaitingTerminal => Icons.hourglass_top,
  CollectionStatus.pendingSync => Icons.cloud_off,
  _ => Icons.pending_actions,
};

IconData methodIcon(String m) => switch (m) {
  TenderMethod.cash => Icons.payments_outlined,
  TenderMethod.cardTerminal => Icons.credit_card,
  TenderMethod.transfer => Icons.account_balance,
  TenderMethod.payLink => Icons.qr_code_2,
  _ => Icons.payment,
};

/// One collection with its clear status (never colour alone: text + icon).
class CollectionTile extends StatelessWidget {
  const CollectionTile(this.c, {super.key, this.showOrder = false});
  final Collection c;
  final bool showOrder;

  @override
  Widget build(BuildContext context) {
    final color = collectionStatusColor(c.status);
    final details = [
      if (showOrder && c.orderNumber != null) c.orderNumber!,
      if (c.approvalCode != null && c.approvalCode!.isNotEmpty)
        'Approval ${c.approvalCode}',
      if (c.cardLast4 != null && c.cardLast4!.isNotEmpty)
        'Card ...${c.cardLast4}',
      if (c.slipReference != null && c.slipReference!.isNotEmpty)
        'Slip ${c.slipReference}',
      if (c.bankReference != null && c.bankReference!.isNotEmpty)
        'Ref ${c.bankReference}',
      if (c.method == TenderMethod.cash && c.tendered != null)
        'Tendered ${money(c.tendered)}',
    ];
    return Container(
      key: Key('collection-${c.id}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
        color: color.withValues(alpha: 0.05),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(methodIcon(c.method), size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '${TenderMethod.label(c.method)}  ${money(c.amount)}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                if (details.isNotEmpty)
                  Text(
                    details.join('  -  '),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                if (c.isRejected && (c.rejectionReason ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Reason: ${c.rejectionReason}',
                      key: Key('reject-reason-${c.id}'),
                      style: const TextStyle(
                        color: R007Colors.red,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (c.status == CollectionStatus.pendingSync)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'Saved on this tablet. Sends automatically when the connection is back.',
                      style: TextStyle(color: R007Colors.orange),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          StatusPill(
            CollectionStatus.label(c.status),
            color,
            icon: collectionStatusIcon(c.status),
          ),
        ],
      ),
    );
  }
}

/// A labelled money figure (amount due / collected / remaining ...).
class AmountFigure extends StatelessWidget {
  const AmountFigure(
    this.label,
    this.value, {
    super.key,
    this.color,
    this.big = false,
  });
  final String label;
  final String? value;
  final Color? color;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
            fontSize: 14,
          ),
        ),
        Text(
          money(value),
          style: TextStyle(
            fontSize: big ? 30 : 20,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      ],
    );
  }
}
