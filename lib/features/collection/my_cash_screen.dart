import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/api/r007_api.dart';
import '../../core/models/collection_models.dart';
import '../../core/state/app_state.dart';
import '../../core/state/collection_service.dart';
import '../../core/util/money.dart';
import '../shared/widgets.dart';
import 'collection_widgets.dart';

/// My cash: what the waiter holds, today's collections, and the hand-over to
/// the cashier (declared amount -> server variance). Shown only when the
/// effective policy lets this waiter hold cash.
class MyCashScreen extends ConsumerStatefulWidget {
  const MyCashScreen({super.key});
  @override
  ConsumerState<MyCashScreen> createState() => MyCashScreenState();
}

class MyCashScreenState extends ConsumerState<MyCashScreen> {
  final _declared = TextEditingController();
  final _note = TextEditingController();
  String _attemptId = newId();
  String _attemptKey = newId();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _declared.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _handover() async {
    if (_busy) return; // duplicate-tap safe
    final d = _declared.text.trim();
    if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(d)) {
      setState(() => _error = 'Count your cash and enter the amount');
      return;
    }
    _busy = true;
    setState(() => _error = null);
    try {
      await ref
          .read(collectionServiceProvider)
          .handover(
            id: _attemptId,
            declaredAmount: d,
            note: _note.text.trim(),
            idempotencyKey: _attemptKey,
          );
      _attemptId = newId();
      _attemptKey = newId();
      ref.invalidate(cashInHandProvider);
      ref.invalidate(myHandoversProvider);
      if (mounted) {
        _declared.clear();
        _note.clear();
      }
    } on ApiProblem catch (e) {
      if (e.status < 500) {
        _attemptId = newId();
        _attemptKey = newId();
      }
      if (mounted) setState(() => _error = describeError(e));
    } on ApiOfflineException {
      if (mounted) {
        setState(
          () => _error =
              'Handing over needs a connection (the server works out any difference). Try again when the tablet is online.',
        );
      }
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final policy =
        ref.watch(collectionPolicyProvider).value ??
        CollectionPolicy.permissive;
    final data = ref.watch(cashInHandProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('My cash'),
        actions: [
          IconButton(
            key: const Key('cash-refresh'),
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(cashInHandProvider),
          ),
        ],
      ),
      body: !policy.cashHoldingAllowed
          ? const EmptyState(
              Icons.payments_outlined,
              'Cash goes to the cashier.\nYou do not hold cash.',
            )
          : data.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(24),
                child: InlineError(
                  describeError(e),
                  onRetry: () => ref.invalidate(cashInHandProvider),
                ),
              ),
              data: (c) => _content(context, c, policy),
            ),
    );
  }

  Widget _content(BuildContext context, CashInHand c, CollectionPolicy policy) {
    final limit = c.limit ?? policy.cashLimit;
    final inHand = Money.toMinor(c.cashInHand);
    final lim = limit == null ? null : Money.toMinor(limit);
    final over =
        c.handoverRequired ||
        (lim != null && lim > BigInt.zero && inHand >= lim);
    final near =
        lim != null &&
        lim > BigInt.zero &&
        !over &&
        inHand * BigInt.from(100) >= lim * BigInt.from(80);
    final warnColor = over ? R007Colors.red : R007Colors.orange;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: AmountFigure(
                              'Cash in hand',
                              c.cashInHand,
                              big: true,
                            ),
                          ),
                          if (limit != null)
                            Expanded(child: AmountFigure('Your limit', limit)),
                          Expanded(
                            child: AmountFigure(
                              'Pending cashier (${c.pendingCollections})',
                              c.pendingCollectionsAmount,
                              color: R007Colors.orange,
                            ),
                          ),
                        ],
                      ),
                      if (over || near)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            key: const Key('limit-warning'),
                            children: [
                              Icon(Icons.warning_amber, color: warnColor),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  over
                                      ? 'You have reached your cash limit. Hand over to the cashier before taking more cash.'
                                      : 'You are close to your cash limit. Hand over soon.',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: warnColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                for (final h
                    in ref.watch(myHandoversProvider).value ??
                        const <CashHandover>[])
                  _resultCard(h),
                const SizedBox(height: 8),
                Text(
                  'Hand over to the cashier',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('declared-field'),
                  controller: _declared,
                  onChanged: (_) => setState(() => _error = null),
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Cash you are handing over (count it)',
                    prefixText: '₦ ',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('handover-note'),
                  controller: _note,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: InlineError(_error!),
                  ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('handover-submit'),
                  onPressed: _busy ? null : _handover,
                  icon: const Icon(Icons.outbox),
                  label: const Text('Hand over to cashier'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(68),
                    textStyle: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                ..._today(context),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _today(BuildContext context) {
    final today = ref.watch(myCollectionsTodayProvider).value ?? const [];
    int n(String st) => today.where((c) => c.status == st).length;
    return [
      Text('Collections today', style: Theme.of(context).textTheme.titleLarge),
      if (today.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Nothing collected yet today.'),
        )
      else
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${today.length} collected: ${n(CollectionStatus.confirmed)} confirmed, '
            '${n(CollectionStatus.pendingConfirmation) + n(CollectionStatus.awaitingPayment)} pending, '
            '${n(CollectionStatus.rejected)} rejected',
            key: const Key('today-summary'),
            style: const TextStyle(fontSize: 16),
          ),
        ),
      for (final x in today) CollectionTile(x, showOrder: true),
    ];
  }

  Widget _resultCard(CashHandover r) {
    final waiting = r.isWaiting;
    final v = Money.toMinor(r.variance);
    final exact = r.varianceKind == 'EXACT' || v == BigInt.zero;
    final color = waiting
        ? R007Colors.blue
        : (exact && !r.requiresSignoff ? R007Colors.green : R007Colors.orange);
    final title = waiting
        ? 'Handover declared - waiting for the cashier to count it'
        : r.status == HandoverStatus.pendingSignoff
        ? 'Counted - a supervisor must sign off the difference'
        : exact
        ? 'Received - no difference'
        : r.varianceKind == 'SHORT'
        ? 'Received - you were SHORT'
        : 'Received - you were OVER';
    return Container(
      key: Key('handover-${r.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 2),
        borderRadius: BorderRadius.circular(16),
        color: color.withValues(alpha: 0.07),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                waiting
                    ? Icons.hourglass_top
                    : (exact ? Icons.check_circle : Icons.rule),
                color: color,
                size: 30,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  key: Key('handover-title-${r.id}'),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 32,
            children: [
              AmountFigure('You declared', r.declaredAmount),
              AmountFigure('Expected in hand', r.expectedInHand),
              if (!waiting) AmountFigure('Cashier counted', r.countedAmount),
              if (!waiting && !exact)
                AmountFigure(
                  v.isNegative ? 'Short by' : 'Over by',
                  Money.fromMinor(v.abs()),
                  color: color,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
