import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/models/models.dart';
import '../../core/state/app_state.dart';
import '../../core/state/sports.dart';
import '../shared/widgets.dart';
import 'scanner_view.dart';

/// Sports Store: scan the entitlement -> see EXACTLY what was paid/rented ->
/// release items / record returns. Duplicate release is blocked by the server;
/// its answer is surfaced verbatim.
class StoreScreen extends ConsumerStatefulWidget {
  const StoreScreen({super.key});
  @override
  ConsumerState<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends ConsumerState<StoreScreen> {
  final Set<String> _selected = {};
  String _condition = 'OK';

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(storeProvider);
    final app = ref.watch(appControllerProvider);
    final builder = ref.watch(scannerBuilderProvider);
    final e = s.entitlement;

    return Scaffold(
      appBar: AppBar(
        title: Text('Sports Store  -  ${app.facilityName ?? ''}'),
        actions: [
          Center(child: Text(app.staff?.name ?? '')),
          if (e != null)
            TextButton.icon(
              key: const Key('store-next'),
              onPressed: () {
                _selected.clear();
                ref.read(storeProvider.notifier).reset();
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Next customer'),
            ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(appControllerProvider.notifier).logout(),
          ),
        ],
      ),
      body: e == null
          ? _scanView(context, s, builder)
          : _entitlementView(context, s, e),
    );
  }

  Widget _scanView(BuildContext context, StoreState s, ScannerBuilder builder) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: AspectRatio(
              aspectRatio: 1,
              child: builder(
                context,
                (c) => ref.read(storeProvider.notifier).lookup(c),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 4,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Scan the customer\'s QR code',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  if (s.busy) const LinearProgressIndicator(),
                  if (s.connectionError != null) ...[
                    InlineError(s.connectionError!),
                    const SizedBox(height: 12),
                  ],
                  if (s.error != null) ...[
                    InlineError(s.error!),
                    const SizedBox(height: 12),
                  ],
                  CodeEntry(
                    onCode: (c) => ref.read(storeProvider.notifier).lookup(c),
                    label: 'Scan or type entitlement QR',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _entitlementView(BuildContext context, StoreState s, Entitlement e) {
    final releasable = e.items.where((i) => i.canRelease).toList();
    final returnable = e.items.where((i) => i.canReturn).toList();
    final selRelease = releasable
        .where((i) => _selected.contains(i.id))
        .map((i) => i.id)
        .toList();
    final selReturn = returnable
        .where((i) => _selected.contains(i.id))
        .map((i) => i.id)
        .toList();

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                e.holderName ?? 'Customer',
                key: const Key('holder'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            StatusPill(
              e.status,
              e.status == 'ACTIVE' ? R007Colors.green : R007Colors.red,
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text('This is exactly what was paid for / rented:'),
        const SizedBox(height: 12),
        if (e.isCancelled)
          const InlineError(
            'This entitlement is CANCELLED. Do not release anything.',
          ),
        if (s.error != null) ...[
          InlineError(s.error!),
          const SizedBox(height: 8),
        ],
        if (s.connectionError != null) ...[
          InlineError(s.connectionError!),
          const SizedBox(height: 8),
        ],
        if (s.notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              s.notice!,
              key: const Key('store-notice'),
              style: const TextStyle(
                color: R007Colors.greenDark,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
          ),
        for (final i in e.items) _itemTile(i),
        const Divider(height: 32),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              key: const Key('release-btn'),
              onPressed: (s.busy || e.isCancelled || selRelease.isEmpty)
                  ? null
                  : () async {
                      await ref
                          .read(storeProvider.notifier)
                          .release(selRelease);
                      setState(_selected.clear);
                    },
              icon: const Icon(Icons.outbox),
              label: Text('Release selected (${selRelease.length})'),
            ),
            SizedBox(
              width: 200,
              child: DropdownButtonFormField<String>(
                key: const Key('condition'),
                isExpanded: true,
                initialValue: _condition,
                decoration: const InputDecoration(labelText: 'Condition'),
                items: const [
                  DropdownMenuItem(value: 'OK', child: Text('OK')),
                  DropdownMenuItem(value: 'DAMAGED', child: Text('Damaged')),
                  DropdownMenuItem(value: 'LOST', child: Text('Lost')),
                ],
                onChanged: (v) => setState(() => _condition = v ?? 'OK'),
              ),
            ),
            OutlinedButton.icon(
              key: const Key('return-btn'),
              onPressed: (s.busy || selReturn.isEmpty)
                  ? null
                  : () async {
                      await ref
                          .read(storeProvider.notifier)
                          .returnItems(selReturn, condition: _condition);
                      setState(_selected.clear);
                    },
              icon: const Icon(Icons.assignment_return),
              label: Text('Record return (${selReturn.length})'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _itemTile(EntitlementItem i) {
    final (label, color) = switch (i.kind) {
      'ACCESS' => (
        i.quantityRedeemed >= i.quantity ? 'ENTERED' : 'ENTRY NOT USED',
        R007Colors.blue,
      ),
      'RENTAL' => switch (i.rentalStatus) {
        'RELEASED' => ('RELEASED - NOT RETURNED', R007Colors.orange),
        'RETURNED' => ('RETURNED', R007Colors.greenDark),
        _ => ('NOT RELEASED', R007Colors.grey),
      },
      _ => (
        i.quantityRedeemed >= i.quantity ? 'RELEASED' : 'NOT RELEASED',
        i.quantityRedeemed >= i.quantity ? R007Colors.orange : R007Colors.grey,
      ),
    };
    final selectable = i.canRelease || i.canReturn;
    return Card(
      child: CheckboxListTile(
        key: Key('item-${i.id}'),
        value: _selected.contains(i.id),
        onChanged: selectable
            ? (v) => setState(() {
                if (v ?? false) {
                  _selected.add(i.id);
                } else {
                  _selected.remove(i.id);
                }
              })
            : null,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          '${i.quantity} x ${i.name}',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          i.kind == 'ACCESS'
              ? 'Entry / booking'
              : (i.kind == 'RENTAL' ? 'Rental' : 'Goods'),
        ),
        secondary: StatusPill(label, color),
      ),
    );
  }
}
