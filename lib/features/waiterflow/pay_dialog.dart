import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../core/models/waiter_flow.dart';
import '../../core/util/money.dart';
import '../shared/widgets.dart';

/// How the customer paid. Shows what is owed, lets the waiter split it over cash / card machine / transfer, asks for the slip or
/// transfer reference, and returns the tenders once the amounts add up exactly. Cash may be over-tendered (change is shown).
Future<List<PayTender>?> askPayment(
  BuildContext context, {
  required String total,
  required int tabCount,
  String? onBehalfOf,
}) => showDialog<List<PayTender>>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _PayDialog(total: total, tabCount: tabCount, onBehalfOf: onBehalfOf),
);

class _Row {
  _Row(this.type, String amount) : amount = TextEditingController(text: amount);
  String type;
  final TextEditingController amount;
  final reference = TextEditingController();
  final given = TextEditingController();
}

const _types = {
  'CASH': 'Cash',
  'POS_TERMINAL': 'Card / POS machine',
  'TRANSFER': 'Bank transfer',
};

class _PayDialog extends StatefulWidget {
  const _PayDialog({
    required this.total,
    required this.tabCount,
    this.onBehalfOf,
  });
  final String total;
  final int tabCount;
  final String? onBehalfOf;
  @override
  State<_PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<_PayDialog> {
  late final List<_Row> _rows = [_Row('CASH', widget.total)];
  String? _error;

  BigInt get _due => Money.toMinor(widget.total);
  BigInt get _entered =>
      _rows.fold(BigInt.zero, (a, r) => a + Money.toMinor(r.amount.text));

  @override
  void dispose() {
    for (final r in _rows) {
      r.amount.dispose();
      r.reference.dispose();
      r.given.dispose();
    }
    super.dispose();
  }

  void _addRow() {
    final left = _due - _entered;
    setState(
      () => _rows.add(
        _Row('POS_TERMINAL', left > BigInt.zero ? Money.fromMinor(left) : ''),
      ),
    );
  }

  void _submit() {
    final tenders = <PayTender>[];
    for (final r in _rows) {
      final amt = r.amount.text.trim();
      if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(amt) ||
          Money.toMinor(amt) <= BigInt.zero) {
        setState(() => _error = 'Enter the amount for every payment method.');
        return;
      }
      String? tendered;
      if (r.type == 'CASH') {
        final g = r.given.text.trim();
        if (g.isNotEmpty) {
          if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(g) ||
              Money.toMinor(g) < Money.toMinor(amt)) {
            setState(
              () => _error = 'Cash given must be at least the cash amount.',
            );
            return;
          }
          tendered = g;
        }
      } else if (r.reference.text.trim().length < 3) {
        setState(
          () => _error =
              'Enter the slip or transfer reference for ${_types[r.type]}.',
        );
        return;
      }
      tenders.add(
        PayTender(
          type: r.type,
          amount: amt,
          reference: r.reference.text.trim(),
          tendered: tendered,
        ),
      );
    }
    if (_entered != _due) {
      setState(
        () => _error =
            'The amounts must add up to ${money(widget.total)}. Now ${money(Money.fromMinor(_entered))}.',
      );
      return;
    }
    Navigator.of(context).pop(tenders);
  }

  @override
  Widget build(BuildContext context) {
    final diff = _due - _entered;
    return AlertDialog(
      title: Text(
        widget.tabCount == 1
            ? 'Take payment'
            : 'Take payment for ${widget.tabCount} tabs',
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                money(widget.total),
                style: Theme.of(
                  context,
                ).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (widget.onBehalfOf != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'On behalf of ${widget.onBehalfOf}',
                    style: const TextStyle(color: R007Colors.purple),
                  ),
                ),
              const SizedBox(height: 12),
              for (var i = 0; i < _rows.length; i++) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: DropdownButtonFormField<String>(
                        key: Key('pay-type-$i'),
                        initialValue: _rows[i].type,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Paid by'),
                        items: [
                          for (final e in _types.entries)
                            DropdownMenuItem(
                              value: e.key,
                              child: Text(
                                e.value,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) =>
                            setState(() => _rows[i].type = v ?? _rows[i].type),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 4,
                      child: TextField(
                        key: Key('pay-amount-$i'),
                        controller: _rows[i].amount,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Amount',
                          prefixText: '₦ ',
                        ),
                        onChanged: (_) => setState(() => _error = null),
                      ),
                    ),
                    if (_rows.length > 1)
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _rows.removeAt(i)),
                      ),
                  ],
                ),
                if (_rows[i].type == 'CASH')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextField(
                      key: Key('pay-given-$i'),
                      controller: _rows[i].given,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      decoration: const InputDecoration(
                        labelText:
                            'Cash given by the customer (optional, to show change)',
                        prefixText: '₦ ',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextField(
                      key: Key('pay-ref-$i'),
                      controller: _rows[i].reference,
                      decoration: InputDecoration(
                        labelText: _rows[i].type == 'TRANSFER'
                            ? 'Transfer reference / session ID'
                            : 'Slip / RRN number from the machine',
                      ),
                    ),
                  ),
                if (_rows[i].type == 'CASH' &&
                    _rows[i].given.text.trim().isNotEmpty)
                  Builder(
                    builder: (_) {
                      final change =
                          Money.toMinor(_rows[i].given.text) -
                          Money.toMinor(_rows[i].amount.text);
                      if (change <= BigInt.zero) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Change to give: ${money(Money.fromMinor(change))}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: R007Colors.greenDark,
                          ),
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 12),
              ],
              if (_rows.length < 3)
                TextButton.icon(
                  key: const Key('pay-add-method'),
                  onPressed: _addRow,
                  icon: const Icon(Icons.add),
                  label: const Text('Split: add another payment method'),
                ),
              if (diff != BigInt.zero)
                Text(
                  diff > BigInt.zero
                      ? 'Still to cover: ${money(Money.fromMinor(diff))}'
                      : 'Over by ${money(Money.fromMinor(-diff))}',
                  style: const TextStyle(
                    color: R007Colors.orange,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: R007Colors.red),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('pay-confirm'),
          onPressed: _submit,
          child: Text('Confirm ${money(widget.total)} received'),
        ),
      ],
    );
  }
}
