import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/r007_api.dart';
import '../../core/models/models.dart';
import '../../core/offline/offline_queue.dart';
import '../../core/state/app_state.dart';
import '../../core/state/attendant_state.dart';
import '../../core/state/board.dart';
import '../../core/state/order_service.dart';
import '../../core/util/money.dart';
import '../shared/widgets.dart';

/// Catalog browse (categories -> products, per facility) + cart + send.
/// The cart shows a labelled ESTIMATE only; the server prices and locks.
class MenuScreen extends ConsumerStatefulWidget {
  const MenuScreen({super.key});
  @override
  ConsumerState<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends ConsumerState<MenuScreen> {
  String? _categoryId;
  bool _sending = false;

  /// Server-side DRAFT left behind by a refused send (see PartialSubmitException).
  String? _draftOrderId;

  @override
  void initState() {
    super.initState();
    // New order screen always starts with an empty cart.
    Future.microtask(() => ref.read(cartProvider.notifier).clear());
  }

  Future<void> _addProduct(Product p) async {
    if (!p.available) return;
    if (p.modifierGroups.isEmpty) {
      ref.read(cartProvider.notifier).add(p);
      return;
    }
    final picked = await showDialog<List<ModifierOption>>(
      context: context,
      builder: (_) => _ModifierDialog(product: p),
    );
    if (picked != null) {
      ref.read(cartProvider.notifier).add(p, modifiers: picked);
    }
  }

  Future<void> _send() async {
    final cart = ref.read(cartProvider);
    final sel = ref.read(selectionProvider);
    final facilityId = ref.read(appControllerProvider).facilityId;
    if (cart.isEmpty || sel == null || facilityId == null) return;
    setState(() => _sending = true);
    try {
      final board = ref.read(boardProvider);
      final table = board.tables.where((t) => t.id == sel.tableId).firstOrNull;
      final draft = OrderDraft(
        id: newId(),
        facilityId: facilityId,
        tableId: sel.tableId,
        tableName: table?.name,
        tabId: sel.tabId ?? table?.tabId,
        customerName: sel.customerName,
        lines: cart,
      );
      final svc = ref.read(orderServiceProvider);
      final result = _draftOrderId != null
          ? await svc.resubmit(_draftOrderId!, cart)
          : await svc.submit(
              draft,
              openTable: table != null && table.isFree,
              createTab: sel.newCustomer,
              customerName: sel.customerName,
            );
      _draftOrderId = null;
      ref.read(cartProvider.notifier).clear();
      if (sel.newCustomer && mounted) {
        // Show the queued/new order under the customer once it exists.
        ref
            .read(selectionProvider.notifier)
            .select(
              Selection(tabId: result.tabId, customerName: sel.customerName),
            );
      }
      unawaited(ref.read(boardProvider.notifier).refresh(silent: true));
      if (!mounted) return;
      toast(
        context,
        result.queued
            ? 'No connection - order saved and will be sent automatically'
            : 'Order sent',
      );
      context.pop();
    } on PartialSubmitException catch (e) {
      _draftOrderId = e.orderId;
      if (mounted) toast(context, describeError(e.problem), error: true);
    } on QueueBlockedException catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(catalogProvider);
    final cart = ref.watch(cartProvider);
    final sel = ref.watch(selectionProvider);
    final board = ref.watch(boardProvider);
    final table = board.tables.where((t) => t.id == sel?.tableId).firstOrNull;
    final title = table?.name ?? sel?.customerName ?? 'Customer';

    return Scaffold(
      appBar: AppBar(title: Text('Order for $title')),
      body: catalog.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: InlineError(
              describeError(e),
              onRetry: () => ref.invalidate(catalogProvider),
            ),
          ),
        ),
        data: (c) {
          final cats = c.categories.isEmpty
              ? [const Category(id: '', name: 'All')]
              : c.categories;
          final cat = _categoryId ?? cats.first.id;
          final products = c.products
              .where((p) => c.categories.isEmpty || p.categoryId == cat)
              .toList();
          return Row(
            children: [
              SizedBox(
                width: 190,
                child: ListView(
                  children: [
                    for (final k in cats)
                      ListTile(
                        key: Key('cat-${k.id}'),
                        selected: k.id == cat,
                        selectedTileColor: Theme.of(
                          context,
                        ).colorScheme.primaryContainer,
                        title: Text(
                          k.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        onTap: () => setState(() => _categoryId = k.id),
                      ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: products.isEmpty
                    ? const EmptyState(
                        Icons.restaurant_menu,
                        'Nothing in this category',
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 200,
                              mainAxisExtent: 110,
                              crossAxisSpacing: 10,
                              mainAxisSpacing: 10,
                            ),
                        itemCount: products.length,
                        itemBuilder: (_, i) {
                          final p = products[i];
                          return Card(
                            key: Key('product-${p.id}'),
                            color: p.available
                                ? null
                                : Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                            child: InkWell(
                              onTap: p.available ? () => _addProduct(p) : null,
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        p.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      p.available
                                          ? money(p.price)
                                          : 'UNAVAILABLE',
                                      style: TextStyle(
                                        color: p.available
                                            ? null
                                            : R007Colors.red,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const VerticalDivider(width: 1),
              SizedBox(
                width: 360,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        'Cart',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Expanded(
                      child: cart.isEmpty
                          ? const EmptyState(
                              Icons.shopping_cart_outlined,
                              'Tap items to add them',
                            )
                          : ListView(
                              children: [
                                for (final l in cart)
                                  ListTile(
                                    key: Key('cart-${l.lineId}'),
                                    title: Text(
                                      l.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    subtitle: Text(
                                      [
                                        ...l.modifierNames,
                                        if (l.note != null) l.note!,
                                        'est. ${money(Money.times(l.estUnitPrice, l.quantity))}',
                                      ].join('  -  '),
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          key: Key('dec-${l.lineId}'),
                                          icon: const Icon(
                                            Icons.remove_circle_outline,
                                          ),
                                          onPressed: () => ref
                                              .read(cartProvider.notifier)
                                              .decrement(l.lineId),
                                        ),
                                        Text(
                                          '${l.quantity}',
                                          style: const TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        IconButton(
                                          key: Key('inc-${l.lineId}'),
                                          icon: const Icon(
                                            Icons.add_circle_outline,
                                          ),
                                          onPressed: () => ref
                                              .read(cartProvider.notifier)
                                              .increment(l.lineId),
                                        ),
                                      ],
                                    ),
                                    onLongPress: () async {
                                      final n = await askReason(
                                        context,
                                        title: 'Note for ${l.name}',
                                        label: 'e.g. no pepper',
                                      );
                                      if (n != null) {
                                        ref
                                            .read(cartProvider.notifier)
                                            .setNote(l.lineId, n);
                                      }
                                    },
                                  ),
                              ],
                            ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Estimated total',
                                  style: TextStyle(fontSize: 16),
                                ),
                              ),
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    money(
                                      ref.read(cartProvider.notifier).estimate,
                                    ),
                                    key: const Key('cart-estimate'),
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const Text(
                            'Final prices and tax are set by the server.',
                            style: TextStyle(
                              fontStyle: FontStyle.italic,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 10),
                          FilledButton.icon(
                            key: const Key('send-order'),
                            onPressed:
                                (cart.isEmpty ||
                                    _sending ||
                                    !(ref
                                        .watch(appControllerProvider)
                                        .can('order.send')))
                                ? null
                                : _send,
                            icon: _sending
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.send),
                            label: const Text('Send order'),
                          ),
                          const Text(
                            'Sending locks the items. Add more later as a new order.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ModifierDialog extends StatefulWidget {
  const _ModifierDialog({required this.product});
  final Product product;
  @override
  State<_ModifierDialog> createState() => _ModifierDialogState();
}

class _ModifierDialogState extends State<_ModifierDialog> {
  final Map<String, Set<String>> _picked = {};

  bool get _valid => widget.product.modifierGroups.every(
    (g) => (_picked[g.id]?.length ?? 0) >= g.minSelect,
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.product.name),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final g in widget.product.modifierGroups) ...[
                Text(
                  '${g.name}${g.required ? ' (required)' : ''}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final o in g.options)
                      FilterChip(
                        key: Key('mod-${o.id}'),
                        label: Text(
                          Money.toMinor(o.priceDelta) > BigInt.zero
                              ? '${o.name} +${money(o.priceDelta)}'
                              : o.name,
                        ),
                        selected: _picked[g.id]?.contains(o.id) ?? false,
                        onSelected: (on) => setState(() {
                          final s = _picked.putIfAbsent(g.id, () => {});
                          if (on) {
                            if (g.maxSelect == 1) s.clear();
                            if (s.length < g.maxSelect) s.add(o.id);
                          } else {
                            s.remove(o.id);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
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
          key: const Key('mod-add'),
          onPressed: _valid
              ? () => Navigator.of(context).pop([
                  for (final g in widget.product.modifierGroups)
                    for (final o in g.options)
                      if (_picked[g.id]?.contains(o.id) ?? false) o,
                ])
              : null,
          child: const Text('Add to cart'),
        ),
      ],
    );
  }
}
