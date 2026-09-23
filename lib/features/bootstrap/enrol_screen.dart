import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/app_state.dart';
import '../shared/widgets.dart';

/// One-time device enrolment with the registration code IT issued in the
/// admin UI. The returned device credential is kept in secure storage and sent
/// as `X-Device-Token` on every request.
class EnrolScreen extends ConsumerStatefulWidget {
  const EnrolScreen({super.key});
  @override
  ConsumerState<EnrolScreen> createState() => _EnrolScreenState();
}

class _EnrolScreenState extends ConsumerState<EnrolScreen> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  String _mode = 'ATTENDANT';
  bool _busy = false;
  String? _error;

  Future<void> _enrol() async {
    if (_name.text.trim().isEmpty || _code.text.trim().isEmpty) {
      setState(() => _error = 'Enter a tablet name and the registration code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(appControllerProvider.notifier)
          .enrol(name: _name.text.trim(), code: _code.text.trim(), mode: _mode);
    } on Object catch (e, st) {
      debugPrint('enrol failed: $e\n$st');
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mock = ref.watch(appConfigProvider).useMock;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(32),
            children: [
              const Icon(Icons.tablet_android, size: 64),
              const SizedBox(height: 16),
              Text(
                'Enrol this tablet',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'IT gives you a one-time registration code. The role you pick is recorded on the server.',
              ),
              const SizedBox(height: 24),
              TextField(
                key: const Key('enrol-name'),
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Tablet name (e.g. Waiter Tablet 03)',
                  prefixIcon: Icon(Icons.label_outline),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('enrol-code'),
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Registration code',
                  prefixIcon: Icon(Icons.vpn_key_outlined),
                ),
                onSubmitted: (_) => _enrol(),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: const Key('enrol-mode'),
                isExpanded: true,
                initialValue: _mode,
                decoration: const InputDecoration(
                  labelText: 'Tablet role',
                  prefixIcon: Icon(Icons.devices_other),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'ATTENDANT',
                    child: Text('Attendant (waiter / bartender / cashier)'),
                  ),
                  DropdownMenuItem(
                    value: 'SUPERVISOR',
                    child: Text('Supervisor (approvals)'),
                  ),
                  DropdownMenuItem(
                    value: 'SPORTS_ENTRANCE',
                    child: Text('Sports Entrance scanner'),
                  ),
                  DropdownMenuItem(
                    value: 'SPORTS_STORE',
                    child: Text('Sports Store (release / return)'),
                  ),
                ],
                onChanged: (v) => setState(() => _mode = v ?? _mode),
              ),
              if (mock) ...[
                const SizedBox(height: 16),
                Card(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'DEMO codes:\n'
                      'ATT-2026  Waiter (attendant) tablet\n'
                      'SUP-2026  Supervisor tablet (Restaurant)\n'
                      'ENT-2026  Sports Entrance scanner\n'
                      'STO-2026  Sports Store tablet',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 15),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (_error != null) InlineError(_error!),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('enrol-submit'),
                onPressed: _busy ? null : _enrol,
                child: _busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Enrol tablet'),
              ),
              if (!mock)
                TextButton(
                  onPressed: () =>
                      ref.read(appControllerProvider.notifier).forgetServer(),
                  child: const Text('Change server address'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
