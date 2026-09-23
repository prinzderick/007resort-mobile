import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/state/app_state.dart';
import '../shared/widgets.dart';

/// Tablet checkout at shift start (spec section 5): device -> staff ->
/// facility. Recorded by the server with checkout time; returned at shift end.
class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key});
  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  List<Facility>? _facilities;
  String? _loadError;
  Facility? _selected;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final all = await ref.read(apiProvider).listFacilities();
      final mine =
          ref.read(appControllerProvider).staff?.facilityIds ?? const [];
      // The server enforces scope; this only narrows the picker.
      final list = mine.isEmpty
          ? all
          : all.where((f) => mine.contains(f.id)).toList();
      if (mounted) setState(() => _facilities = list);
    } on Object catch (e) {
      if (mounted) setState(() => _loadError = describeError(e));
    }
  }

  Future<void> _checkout() async {
    final f = _selected;
    if (f == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(appControllerProvider.notifier)
          .checkoutTablet(facility: f);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final staff = ref.watch(appControllerProvider.select((s) => s.staff));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Check out this tablet'),
        actions: [
          TextButton(
            onPressed: () => ref.read(appControllerProvider.notifier).logout(),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Hello ${staff?.name ?? ''}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              const Text(
                'Where are you working this shift? The tablet is recorded against you and that facility until you return it.',
              ),
              const SizedBox(height: 20),
              if (_loadError != null) InlineError(_loadError!, onRetry: _load),
              if (_facilities == null && _loadError == null)
                const Center(child: CircularProgressIndicator()),
              if (_facilities != null && _facilities!.isEmpty)
                const EmptyState(
                  Icons.storefront_outlined,
                  'No facilities are assigned to you. Ask a supervisor.',
                ),
              if (_facilities != null)
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final f in _facilities!)
                      SizedBox(
                        width: 220,
                        height: 96,
                        child: ChoiceChip(
                          key: Key('facility-${f.id}'),
                          selected: _selected?.id == f.id,
                          onSelected: (_) => setState(() => _selected = f),
                          label: SizedBox(
                            width: 190,
                            child: Text(
                              f.name,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          showCheckmark: true,
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 24),
              if (_error != null) ...[
                InlineError(_error!),
                const SizedBox(height: 12),
              ],
              FilledButton.icon(
                key: const Key('checkout-submit'),
                onPressed: (_selected == null || _busy) ? null : _checkout,
                icon: const Icon(Icons.login),
                label: const Text('Check out tablet'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
