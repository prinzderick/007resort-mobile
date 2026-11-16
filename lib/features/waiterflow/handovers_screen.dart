import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/models/waiter_flow.dart';
import '../../core/state/app_state.dart';
import '../../core/state/board.dart';
import '../../core/state/waiter_flow_state.dart';
import '../../core/util/money.dart';
import '../shared/widgets.dart';

/// Waiter-only flow: hand my open tabs to a colleague (they must accept on their tablet), and accept tabs handed to me.
class HandoversScreen extends ConsumerStatefulWidget {
  const HandoversScreen({super.key});
  @override
  ConsumerState<HandoversScreen> createState() => HandoversScreenState();
}

class HandoversScreenState extends ConsumerState<HandoversScreen> {
  List<Colleague>? _colleagues;
  String? _to;
  final _note = TextEditingController();
  bool _busy = false;
  String _attemptKey = newId();

  @override
  void initState() {
    super.initState();
    unawaited(_loadColleagues());
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadColleagues() async {
    final facilityId = ref.read(appControllerProvider).facilityId;
    if (facilityId == null) return;
    try {
      final c = await ref.read(apiProvider).waiterColleagues(facilityId);
      if (mounted) setState(() => _colleagues = c);
    } on Object {
      if (mounted) setState(() => _colleagues = const []);
    }
  }

  Future<void> _run(Future<void> Function() f, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
      ref
        ..invalidate(incomingHandoversProvider)
        ..invalidate(outgoingHandoversProvider)
        ..invalidate(openItemsProvider);
      unawaited(ref.read(boardProvider.notifier).refresh(silent: true));
      if (mounted) toast(context, done);
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final me = app.staff?.id;
    final incoming =
        ref.watch(incomingHandoversProvider).value ?? const <TabHandover>[];
    final outgoing =
        ref.watch(outgoingHandoversProvider).value ?? const <TabHandover>[];
    final mine = [
      for (final g
          in ref.watch(openItemsProvider).value?.groups ?? const <TabGroup>[])
        if (g.ownerStaffId == me && !g.handoverPending) g,
    ];
    final api = ref.read(apiProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Hand over tabs')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Handed to me', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (incoming.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Nothing is waiting for you to accept.'),
            )
          else
            for (final h in incoming)
              Card(
                key: Key('incoming-${h.id}'),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${h.fromName} wants to hand you ${h.items.length} order${h.items.length == 1 ? '' : 's'}  -  ${money(h.balance)} owed',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        h.items
                            .map(
                              (i) => [i.number, i.tableLabel, i.customerName]
                                  .whereType<String>()
                                  .where((s) => s.isNotEmpty)
                                  .join(' '),
                            )
                            .join('   |   '),
                      ),
                      if (h.note != null && h.note!.isNotEmpty)
                        Text(
                          'Note: ${h.note}',
                          style: const TextStyle(fontStyle: FontStyle.italic),
                        ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            key: Key('reject-${h.id}'),
                            onPressed: _busy
                                ? null
                                : () => _run(() async {
                                    await api.rejectTabHandover(
                                      h.id,
                                      idempotencyKey: newId(),
                                    );
                                  }, 'Declined'),
                            child: const Text('Decline'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            key: Key('accept-${h.id}'),
                            onPressed: _busy
                                ? null
                                : () => _run(() async {
                                    await api.acceptTabHandover(
                                      h.id,
                                      idempotencyKey: newId(),
                                    );
                                  }, 'Accepted: the tabs are yours now'),
                            child: const Text('Accept'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          const Divider(height: 32),
          Text(
            'Hand over my tabs',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          if (mine.isEmpty)
            const Text('You have no open tabs to hand over.')
          else ...[
            Text(
              '${mine.length} open tab${mine.length == 1 ? '' : 's'}  -  ${money(Money.sum(mine.map((g) => g.balance)))} owed. '
              'They move only after the other waiter accepts.',
            ),
            const SizedBox(height: 12),
            if (_colleagues == null)
              const LinearProgressIndicator()
            else
              DropdownButtonFormField<String>(
                key: const Key('handover-to'),
                initialValue: _to,
                decoration: const InputDecoration(labelText: 'Hand over to'),
                items: [
                  for (final c in _colleagues!)
                    DropdownMenuItem(value: c.staffId, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => _to = v),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const Key('handover-send'),
                onPressed: _to == null || _busy
                    ? null
                    : () => _run(() async {
                        await api.requestTabHandover(
                          facilityId: app.facilityId!,
                          toStaffId: _to!,
                          note: _note.text.trim(),
                          idempotencyKey: _attemptKey,
                        );
                        _attemptKey = newId();
                        _note.clear();
                      }, 'Sent. They must accept it on their tablet.'),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Send hand-over'),
              ),
            ),
          ],
          if (outgoing.isNotEmpty) ...[
            const Divider(height: 32),
            Text(
              'Waiting to be accepted',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            for (final h in outgoing)
              Card(
                key: Key('outgoing-${h.id}'),
                child: ListTile(
                  title: Text(
                    'To ${h.toName}  -  ${h.items.length} order${h.items.length == 1 ? '' : 's'}  -  ${money(h.balance)}',
                  ),
                  subtitle: const Text('Still yours until they accept.'),
                  trailing: TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await api.cancelTabHandover(
                              h.id,
                              idempotencyKey: newId(),
                            );
                          }, 'Cancelled'),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 24),
          const Text(
            'A hand-over expires after 30 minutes if it is not accepted.',
            style: TextStyle(color: R007Colors.grey),
          ),
        ],
      ),
    );
  }
}
