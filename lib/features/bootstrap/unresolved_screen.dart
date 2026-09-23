import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/app_state.dart';

/// Shown when the device role could not be determined (unsupported device
/// kind, or the home facility could not be read). Never unlocks a UI.
class UnresolvedScreen extends ConsumerWidget {
  const UnresolvedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(appControllerProvider.select((s) => s.device));
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.help_outline, size: 64),
              const SizedBox(height: 16),
              Text(
                'Tablet role not resolved',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Device: ${d?.name ?? '-'} (${d?.kind ?? '-'}). Ask IT to check its registration.',
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => ref
                    .read(appControllerProvider.notifier)
                    .resolveDeviceMode(),
                child: const Text('Try again'),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(appControllerProvider.notifier).logout(),
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
