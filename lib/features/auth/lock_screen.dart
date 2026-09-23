import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/app_state.dart';
import '../shared/widgets.dart';

/// Shown after idle timeout / app restart: the SAME staff member must
/// re-enter their PIN (or tap their NFC card). Checkout and unsent work are
/// preserved.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});
  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _pin = TextEditingController();
  final _nfc = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _unlock({bool nfc = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(appControllerProvider.notifier)
          .unlock(
            secret: nfc ? _nfc.text.trim() : _pin.text,
            credentialType: nfc ? 'NFC_CARD' : 'PIN',
          );
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = describeError(e));
        _pin.clear();
        _nfc.clear();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final staff = ref.watch(appControllerProvider.select((s) => s.staff));
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 64),
                const SizedBox(height: 12),
                Text(
                  'Tablet locked',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                Text('${staff?.name ?? ''} - enter your PIN to continue'),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('lock-pin'),
                  controller: _pin,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'PIN',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  onSubmitted: (_) => _unlock(),
                ),
                const SizedBox(height: 8),
                PinPad(controller: _pin),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  InlineError(_error!),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('lock-submit'),
                    onPressed: _busy ? null : _unlock,
                    child: const Text('Unlock'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _nfc,
                  decoration: const InputDecoration(
                    labelText: 'or tap NFC card',
                    prefixIcon: Icon(Icons.nfc),
                  ),
                  onSubmitted: (_) => _unlock(nfc: true),
                ),
                TextButton(
                  onPressed: () =>
                      ref.read(appControllerProvider.notifier).logout(),
                  child: const Text('Not me - sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
