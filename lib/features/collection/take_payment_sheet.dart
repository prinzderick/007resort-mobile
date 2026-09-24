import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/api/r007_api.dart';
import '../../core/models/collection_models.dart';
import '../../core/models/models.dart';
import '../../core/offline/offline_queue.dart';
import '../../core/state/app_state.dart';
import '../../core/state/board.dart';
import '../../core/state/collection_service.dart';
import '../../core/state/connectivity.dart';
import '../../core/util/money.dart';
import '../shared/widgets.dart';
import 'collection_widgets.dart';

Future<void> showTakePaymentSheet(BuildContext context, String orderId) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 1100),
      // Shrink above the on-screen keyboard so the fields being typed in
      // are never hidden behind it.
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: FractionallySizedBox(
          heightFactor: 0.94,
          child: TakePaymentSheet(orderId: orderId),
        ),
      ),
    );

/// Take payment at the customer's table. Records what the waiter collected
/// (cash, bank POS machine slip, transfer, pay link) - it NEVER settles the
/// bill: every result is pending the cashier / provider confirmation.
class TakePaymentSheet extends ConsumerStatefulWidget {
  const TakePaymentSheet({super.key, required this.orderId});
  final String orderId;

  @override
  ConsumerState<TakePaymentSheet> createState() => TakePaymentSheetState();
}

class TakePaymentSheetState extends ConsumerState<TakePaymentSheet> {
  String? _method;
  final _amount = TextEditingController();
  final _tendered = TextEditingController();
  final _approval = TextEditingController();
  final _last4 = TextEditingController();
  final _slip = TextEditingController();
  final _bankRef = TextEditingController();
  final _email = TextEditingController();

  /// One client id + Idempotency-Key per on-screen attempt: a double tap, a
  /// retry after a timeout or an offline replay is always the SAME request.
  String _attemptId = newId();
  String _attemptKey = newId();
  bool _busy = false;
  String? _error;
  String? _notice;

  /// The pay link / transfer collection being waited on.
  Collection? _active;
  Order? _lastOrder;
  Timer? _poll;
  Timer? _noticeTimer;
  bool _amountEdited = false;
  String? _seededFor;

  @override
  void initState() {
    super.initState();
    if (ref.read(timersEnabledProvider)) {
      _poll = Timer.periodic(const Duration(seconds: 3), (_) {
        if (_active != null && !_active!.isConfirmed) {
          ref.invalidate(orderCollectionsProvider(widget.orderId));
          unawaited(ref.read(boardProvider.notifier).refresh(silent: true));
        }
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _noticeTimer?.cancel();
    for (final c in [
      _amount,
      _tendered,
      _approval,
      _last4,
      _slip,
      _bankRef,
      _email,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Shows a confirmation banner for a few seconds (a later rejection must
  /// not sit under a stale "recorded" message).
  void _showNotice(String text) {
    _notice = text;
    _noticeTimer?.cancel();
    if (ref.read(timersEnabledProvider)) {
      _noticeTimer = Timer(const Duration(seconds: 8), () {
        if (mounted) setState(() => _notice = null);
      });
    }
  }

  void _newAttempt() {
    _attemptId = newId();
    _attemptKey = newId();
  }

  String _plain(String? v) =>
      v == null ? '' : Money.fromMinor(Money.toMinor(v));

  /// Pre-fills the amount with the SERVER's remaining and keeps it in step
  /// while the waiter has not typed their own figure (a collection recorded a
  /// moment ago changes the remaining once the board refreshes).
  void _seedAmount(String? r) {
    if (r == null || _amountEdited || r == _seededFor) return;
    _seededFor = r;
    _amount.text = _plain(r);
  }

  static final _moneyRe = RegExp(r'^\d{1,9}(\.\d{1,2})?$');

  String? _validate(String method) {
    final amount = _amount.text.trim();
    if (!_moneyRe.hasMatch(amount) || Money.toMinor(amount) <= BigInt.zero) {
      return 'Enter the amount being paid';
    }
    switch (method) {
      case TenderMethod.cash:
        final t = _tendered.text.trim();
        if (!_moneyRe.hasMatch(t)) return 'Enter the cash received';
        if (Money.toMinor(t) < Money.toMinor(amount)) {
          return 'Cash received is less than the amount';
        }
      case TenderMethod.cardTerminal:
        if (_approval.text.trim().length < 3) {
          return 'Enter the approval code printed by the card machine';
        }
        final l4 = _last4.text.trim();
        if (l4.isNotEmpty && !RegExp(r'^\d{4}$').hasMatch(l4)) {
          return 'Last 4 digits of the card must be exactly 4 numbers';
        }
    }
    return null;
  }

  Future<void> _submit(String method, Order order) async {
    if (_busy) return; // duplicate-tap safe (checked synchronously)
    final problem = _validate(method);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    _busy = true;
    setState(() {
      _error = null;
      _notice = null;
    });
    final req = CollectionRequest(
      id: _attemptId,
      orderId: order.id,
      orderNumber: order.number,
      method: method,
      amount: _amount.text.trim(),
      tendered: method == TenderMethod.cash ? _tendered.text.trim() : null,
      approvalCode: method == TenderMethod.cardTerminal
          ? _approval.text.trim()
          : null,
      cardLast4: method == TenderMethod.cardTerminal
          ? _last4.text.trim()
          : null,
      slipReference: method == TenderMethod.cardTerminal
          ? _slip.text.trim()
          : null,
      bankReference: method == TenderMethod.transfer
          ? _bankRef.text.trim()
          : null,
      customerEmail: method == TenderMethod.payLink ? _email.text.trim() : null,
      collectedAt: DateTime.now().toUtc(),
    );
    try {
      final res = await ref
          .read(collectionServiceProvider)
          .collect(req, idempotencyKey: _attemptKey);
      _newAttempt();
      ref.invalidate(orderCollectionsProvider(widget.orderId));
      unawaited(ref.read(boardProvider.notifier).refresh(silent: true));
      if (!mounted) return;
      if (res.queued) {
        _resetForm(order);
        setState(
          () => _showNotice(
            'Saved on this tablet - pending sync. It will be sent as soon as the connection is back.',
          ),
        );
      } else if (res.collection!.isWaiting) {
        setState(() => _active = res.collection);
      } else {
        _resetForm(order);
        setState(
          () => _showNotice(
            'Recorded. Waiting for the cashier to confirm - the bill is not paid until then.',
          ),
        );
      }
    } on ApiProblem catch (e) {
      // A 5xx is ambiguous (it may have been applied): keep the same attempt
      // id so a retry is a replay. Anything definitive starts a new attempt.
      if (e.status < 500) _newAttempt();
      if (!mounted) return;
      await _handleProblem(e);
    } on ApiOfflineException {
      if (mounted) {
        setState(
          () => _error = TenderMethod.needsNetwork(method)
              ? 'A pay link / transfer account needs a connection. Try again when the tablet is online, or use cash / card machine.'
              : 'Cannot reach the server.',
        );
      }
    } on QueueBlockedException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _handleProblem(ApiProblem e) async {
    switch (e.code) {
      case 'cash_limit_exceeded':
        final go = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            key: const Key('cash-limit-dialog'),
            title: const Text('Hand over your cash first'),
            content: Text(
              '${e.detail ?? 'You have reached your cash limit.'}\n\n'
              'Hand your cash over to the cashier, then take this payment.',
              style: const TextStyle(fontSize: 18),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Not now'),
              ),
              FilledButton(
                key: const Key('cash-limit-handover'),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Hand over now'),
              ),
            ],
          ),
        );
        if ((go ?? false) && mounted) {
          final router = GoRouter.of(context);
          Navigator.of(context).pop();
          unawaited(router.push(Routes.cash));
        }
      case 'cash_holding_not_allowed':
        ref.invalidate(collectionPolicyProvider);
        setState(() {
          _method = null;
          _error = 'Cash goes to the cashier. You cannot hold cash.';
        });
      default:
        setState(() => _error = describeError(e));
    }
  }

  void _resetForm(Order order) {
    for (final c in [_tendered, _approval, _last4, _slip, _bankRef, _email]) {
      c.clear();
    }
    _amountEdited = false;
    _seededFor = null;
    _amount.clear();
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(boardProvider);
    final live = board.orderById(widget.orderId);
    if (live != null) _lastOrder = live;
    final order = live ?? _lastOrder;
    final policy =
        ref.watch(collectionPolicyProvider).value ??
        CollectionPolicy.permissive;
    final online = ref.watch(connectivityProvider.select((c) => c.online));
    final server = ref.watch(orderCollectionsProvider(widget.orderId)).value;
    final serverIds = {for (final c in server ?? const <Collection>[]) c.id};
    final sync = [
      for (final c in ref.watch(pendingSyncCollectionsProvider(widget.orderId)))
        if (!serverIds.contains(c.id)) c,
    ];

    if (order == null) {
      return const EmptyState(
        Icons.receipt_long,
        'This bill is no longer open',
      );
    }
    final remaining = order.bill.remainingAfter(sync);
    _seedAmount(remaining);

    // Live state of the waited-on collection.
    Collection? active = _active;
    if (active != null && server != null) {
      final live = server.where((c) => c.id == active!.id).firstOrNull;
      if (live != null) active = active.withLiveState(live);
    }

    final offered = [
      for (final m in TenderMethod.all)
        if (policy.allowedTenders.contains(m)) m,
    ];
    String? disabledReason(String m) {
      if (m == TenderMethod.cash && !policy.cashHoldingAllowed) {
        return 'Cash goes to the cashier';
      }
      if (TenderMethod.needsNetwork(m) && !online) return 'Needs a connection';
      return null;
    }

    final usable = [
      for (final m in offered)
        if (disabledReason(m) == null) m,
    ];
    final method = (_method != null && usable.contains(_method))
        ? _method
        : usable.firstOrNull;
    final bill = order.bill;
    final remainingZero =
        remaining != null && Money.toMinor(remaining) == BigInt.zero;

    return Material(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Take payment  -  ${order.number ?? ''} ${order.tableLabel ?? order.customerName ?? ''}',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  key: const Key('close-payment'),
                  iconSize: 32,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Expanded(
              child: ListView(
                children: [
                  if (live != null)
                    Container(
                      key: const Key('bill-figures'),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          AmountFigure('Amount due', bill.total ?? order.total),
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
                          AmountFigure('Remaining', remaining, big: true),
                        ],
                      ),
                    ),

                  if (active != null)
                    _WaitingView(
                      collection: active,
                      onDone: () => setState(() {
                        _active = null;
                        _resetForm(order);
                      }),
                      onClose: () => Navigator.of(context).pop(),
                    )
                  else if (remainingZero)
                    _Banner(
                      key: const Key('all-collected'),
                      color: R007Colors.blue,
                      icon: Icons.hourglass_top,
                      text:
                          (bill.pending != null &&
                              Money.toMinor(bill.pending) > BigInt.zero)
                          ? 'Everything is collected. Waiting for the cashier to confirm.'
                          : 'This bill is fully paid.',
                    )
                  else ...[
                    if (_notice != null)
                      _Banner(
                        key: const Key('payment-notice'),
                        color: R007Colors.green,
                        icon: Icons.check_circle_outline,
                        text: _notice!,
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final m in offered)
                          _TenderButton(
                            method: m,
                            selected: m == method,
                            disabledReason: disabledReason(m),
                            onTap: () => setState(() {
                              _method = m;
                              _error = null;
                              _notice = null;
                            }),
                          ),
                      ],
                    ),
                    if (method == null)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'No payment method is available right now.',
                          style: TextStyle(fontSize: 18),
                        ),
                      )
                    else
                      _form(method, order, remaining),
                  ],
                  if (sync.isNotEmpty || (server ?? const []).isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'Collections on this bill',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    for (final c in sync) CollectionTile(c),
                    for (final c in server ?? const <Collection>[])
                      CollectionTile(c),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bigField(
    String key,
    String label,
    TextEditingController c, {
    bool money = false,
    bool digits = false,
    int? maxLength,
    String? helper,
    TextCapitalization caps = TextCapitalization.none,
    VoidCallback? onEdited,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      key: Key(key),
      controller: c,
      onChanged: (_) {
        onEdited?.call();
        setState(() => _error = null);
      },
      textInputAction: TextInputAction.next,
      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
      keyboardType: money
          ? const TextInputType.numberWithOptions(decimal: true)
          : digits
          ? TextInputType.number
          : TextInputType.text,
      textCapitalization: caps,
      maxLength: maxLength,
      inputFormatters: [
        if (money) FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        if (digits) FilteringTextInputFormatter.digitsOnly,
      ],
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperStyle: const TextStyle(fontSize: 15),
        border: const OutlineInputBorder(),
        prefixText: money ? '₦ ' : null,
        counterText: '',
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 18,
        ),
      ),
    ),
  );

  Widget _form(String method, Order order, String? remaining) {
    final amount = _amount.text.trim();
    final tendered = _tendered.text.trim();
    String? change;
    if (method == TenderMethod.cash &&
        _moneyRe.hasMatch(amount) &&
        _moneyRe.hasMatch(tendered) &&
        Money.toMinor(tendered) >= Money.toMinor(amount)) {
      // Display-only helper: the server computes the authoritative change.
      change = Money.fromMinor(Money.toMinor(tendered) - Money.toMinor(amount));
    }
    final label = switch (method) {
      TenderMethod.cash => 'Record cash collected',
      TenderMethod.cardTerminal => 'Record card machine payment',
      TenderMethod.transfer =>
        _bankRef.text.trim().isEmpty
            ? 'Show account for this bill'
            : 'Record transfer (pending cashier)',
      _ => 'Create pay link',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _bigField(
                'amount-field',
                'Amount to pay now',
                _amount,
                money: true,
                helper:
                    'Part payments are fine - the rest can use another method.',
              ),
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(top: 12),
              // Not a keyboard "next" stop: Next goes to the following field.
              child: ExcludeFocus(
                child: OutlinedButton(
                  key: const Key('amount-remaining'),
                  onPressed: () => setState(() {
                    _amountEdited = false;
                    _seededFor = null;
                    _amount.text = _plain(remaining);
                  }),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(140, 64),
                  ),
                  child: const Text('Full remaining'),
                ),
              ),
            ),
          ],
        ),
        if (method == TenderMethod.cash) ...[
          _bigField('tendered-field', 'Cash received', _tendered, money: true),
          if (change != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Change to give: ${money(change)}',
                key: const Key('change-due'),
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: R007Colors.greenDark,
                ),
              ),
            ),
        ],
        if (method == TenderMethod.cardTerminal) ...[
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'Charge the customer on the bank POS machine, then type what the machine printed. The cashier confirms it against the slip.',
              style: TextStyle(fontSize: 16),
            ),
          ),
          _bigField(
            'approval-field',
            'Approval code',
            _approval,
            caps: TextCapitalization.characters,
            maxLength: 12,
          ),
          Row(
            children: [
              Expanded(
                child: _bigField(
                  'last4-field',
                  'Card last 4 digits (optional)',
                  _last4,
                  digits: true,
                  maxLength: 4,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _bigField(
                  'slip-field',
                  'Slip / RRN reference (optional)',
                  _slip,
                  maxLength: 30,
                ),
              ),
            ],
          ),
        ],
        if (method == TenderMethod.transfer)
          _bigField(
            'bankref-field',
            'Bank reference (optional)',
            _bankRef,
            maxLength: 40,
            helper:
                'Leave empty to show this bill\'s own account number. Fill it only if the customer already transferred.',
          ),
        if (method == TenderMethod.payLink)
          _bigField(
            'email-field',
            'Customer email (optional)',
            _email,
            helper:
                'The payment provider needs one; a default is used if empty.',
          ),
        if (method == TenderMethod.payLink)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'Creates a payment link and QR code the customer opens on their phone. It confirms by itself when they pay.',
              style: TextStyle(fontSize: 16),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: InlineError(_error!),
          ),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('submit-collection'),
          onPressed: _busy ? null : () => _submit(method, order),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(68),
            textStyle: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          child: _busy
              ? const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              : Text(label),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.color,
    required this.icon,
    required this.text,
  });
  final Color color;
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      border: Border.all(color: color),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(icon, color: color, size: 30),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    ),
  );
}

class _TenderButton extends StatelessWidget {
  const _TenderButton({
    required this.method,
    required this.selected,
    required this.onTap,
    this.disabledReason,
  });
  final String method;
  final bool selected;
  final VoidCallback onTap;
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final disabled = disabledReason != null;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      enabled: !disabled,
      child: InkWell(
        key: Key('tender-$method'),
        borderRadius: BorderRadius.circular(14),
        onTap: disabled ? null : onTap,
        child: Container(
          width: 236,
          height: 108,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: disabled
                ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                : selected
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 3,
            ),
          ),
          child: Row(
            children: [
              Icon(
                methodIcon(method),
                size: 34,
                color: disabled ? scheme.outline : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      TenderMethod.label(method),
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: disabled ? scheme.outline : null,
                      ),
                    ),
                    if (disabled)
                      Text(
                        disabledReason!,
                        key: Key('tender-reason-$method'),
                        style: TextStyle(fontSize: 14, color: scheme.outline),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pay link / transfer account: shows the QR + short link (or the bill's
/// account) and follows the collection live until the provider confirms.
class _WaitingView extends StatelessWidget {
  const _WaitingView({
    required this.collection,
    required this.onDone,
    required this.onClose,
  });
  final Collection collection;
  final VoidCallback onDone;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = collection;
    if (c.isConfirmed) {
      return Column(
        key: const Key('paid-banner'),
        children: [
          const SizedBox(height: 24),
          const Icon(Icons.check_circle, color: R007Colors.green, size: 120),
          Text(
            'PAID  ${money(c.amount)}',
            style: const TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w900,
              color: R007Colors.green,
            ),
          ),
          const Text(
            'Confirmed by the payment provider',
            style: TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('waiting-done'),
            onPressed: onClose,
            style: FilledButton.styleFrom(minimumSize: const Size(220, 64)),
            child: const Text('Done', style: TextStyle(fontSize: 20)),
          ),
        ],
      );
    }
    if (c.isTerminalFailure) {
      return Column(
        key: const Key('waiting-failed'),
        children: [
          const SizedBox(height: 24),
          const Icon(Icons.cancel, color: R007Colors.red, size: 96),
          Text(
            CollectionStatus.label(c.status),
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: R007Colors.red,
            ),
          ),
          if ((c.rejectionReason ?? '').isNotEmpty)
            Text(c.rejectionReason!, style: const TextStyle(fontSize: 18)),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('waiting-retry'),
            onPressed: onDone,
            style: FilledButton.styleFrom(minimumSize: const Size(220, 64)),
            child: const Text('Try again', style: TextStyle(fontSize: 20)),
          ),
        ],
      );
    }
    final isTransfer = c.method == TenderMethod.transfer;
    return Container(
      key: const Key('waiting-view'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        border: Border.all(color: R007Colors.blue, width: 2),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(
            '${TenderMethod.label(c.method)}  ${money(c.amount)}',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          if (!isTransfer && c.qrData != null)
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(
                key: const Key('pay-qr'),
                data: c.qrData!,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
          if (!isTransfer && (c.shortLink ?? c.payLinkUrl) != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SelectableText(
                (c.shortLink ?? c.payLinkUrl)!,
                key: const Key('short-link'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: (c.shortLink ?? c.payLinkUrl)!.length > 28
                      ? 18
                      : 30,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          if (isTransfer) ...[
            _kv('Bank', c.transferBank),
            _kv('Account number', c.transferAccountNumber, big: true),
            _kv('Account name', c.transferAccountName),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'This account is only for this bill. Ask the customer to transfer exactly the amount above.',
                style: TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(width: 12),
              Text(
                c.status == CollectionStatus.awaitingTerminal
                    ? 'Waiting for machine...'
                    : 'Waiting for payment...',
                key: const Key('waiting-label'),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: R007Colors.blue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextButton(
            key: const Key('waiting-back'),
            onPressed: onDone,
            child: const Text(
              'Take a different payment instead',
              style: TextStyle(fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String? v, {bool big = false}) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Column(
      children: [
        Text(k, style: const TextStyle(fontSize: 14)),
        SelectableText(
          v ?? '-',
          style: TextStyle(
            fontSize: big ? 38 : 22,
            fontWeight: FontWeight.w800,
            letterSpacing: big ? 2 : 0,
          ),
        ),
      ],
    ),
  );
}
