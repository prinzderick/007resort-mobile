import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/app_state.dart';
import '../shared/widgets.dart';

/// Staff sign-in: staff number/username + PIN (or password), or an NFC card
/// (wedge readers type the card UID into the NFC field). NFC never works
/// alone on fixed POS; on tablets the server accepts it per the contract.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _id = TextEditingController();
  final _secret = TextEditingController();
  final _nfc = TextEditingController();
  bool _password = false;
  bool _busy = false;
  String? _error;

  Future<void> _submit({bool nfc = false}) async {
    if (_busy) return;
    if (nfc
        ? _nfc.text.trim().isEmpty
        : (_id.text.trim().isEmpty || _secret.text.isEmpty)) {
      setState(
        () => _error = nfc
            ? 'Tap a card on the reader.'
            : 'Enter your staff number and PIN.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(appControllerProvider.notifier)
          .login(
            identifier: nfc ? null : _id.text.trim(),
            secret: nfc ? _nfc.text.trim() : _secret.text,
            credentialType: nfc ? 'NFC_CARD' : (_password ? 'PASSWORD' : 'PIN'),
          );
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = describeError(e));
        _secret.clear();
        _nfc.clear();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            child: Container(
              color: scheme.primaryContainer,
              padding: const EdgeInsets.all(40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.spa_outlined,
                    size: 72,
                    color: scheme.onPrimaryContainer,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '007 Resort & Spa',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${app.mode.label} tablet${app.device == null ? '' : ' - ${app.device!.name}'}',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  if (app.facilityName != null)
                    Text(
                      app.facilityName!,
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontSize: 18,
                      ),
                    ),
                  const SizedBox(height: 32),
                  if (app.checkout != null && app.mode.apiValue == 'ATTENDANT')
                    Text(
                      'Checked out to ${app.checkout!.facility.name}',
                      style: TextStyle(color: scheme.onPrimaryContainer),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Sign in',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        key: const Key('login-id'),
                        controller: _id,
                        decoration: const InputDecoration(
                          labelText: 'Staff number or username',
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('login-secret'),
                        controller: _secret,
                        obscureText: true,
                        keyboardType: _password
                            ? TextInputType.visiblePassword
                            : TextInputType.number,
                        decoration: InputDecoration(
                          labelText: _password ? 'Password' : 'PIN',
                          prefixIcon: const Icon(Icons.lock_outline),
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
                      if (!_password) ...[
                        const SizedBox(height: 8),
                        PinPad(controller: _secret, onSubmit: _submit),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('Use password instead'),
                          Switch(
                            value: _password,
                            onChanged: (v) => setState(() => _password = v),
                          ),
                        ],
                      ),
                      if (_error != null) ...[
                        InlineError(_error!),
                        const SizedBox(height: 12),
                      ],
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          key: const Key('login-submit'),
                          onPressed: _busy ? null : _submit,
                          child: _busy
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Sign in'),
                        ),
                      ),
                      const Divider(height: 32),
                      TextField(
                        key: const Key('login-nfc'),
                        controller: _nfc,
                        decoration: const InputDecoration(
                          labelText: 'Tap NFC card (card reader types here)',
                          prefixIcon: Icon(Icons.nfc),
                        ),
                        onSubmitted: (_) => _submit(nfc: true),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton(
                            onPressed: () => _confirmReset(context),
                            child: const Text('Reset tablet enrolment'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset this tablet?'),
        content: const Text(
          'The tablet forgets its enrolment. IT must issue a new registration code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok ?? false) {
      await ref.read(appControllerProvider.notifier).resetDevice();
    }
  }
}
