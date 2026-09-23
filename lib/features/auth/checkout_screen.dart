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
                      _FacilityTile(
                        key: Key('facility-${f.id}'),
                        facility: f,
                        selected: _selected?.id == f.id,
                        onTap: () => setState(() => _selected = f),
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

class _FacilityTile extends StatelessWidget {
  const _FacilityTile({
    super.key,
    required this.facility,
    required this.selected,
    required this.onTap,
  });
  final Facility facility;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 224,
      height: 96,
      child: Material(
        color: selected ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.check_circle : Icons.storefront_outlined,
                  color: selected ? scheme.onPrimary : scheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    facility.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: selected ? scheme.onPrimary : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
