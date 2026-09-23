import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/r007_api.dart';
import '../../core/state/app_state.dart';
import '../shared/widgets.dart';

/// First launch: where is the 007 Resort server on the property network?
/// (e.g. `http://192.168.1.10:8080` - the Local node). Verified against
/// `GET /api/v1/system/info` before being saved.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});
  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _url = TextEditingController(text: 'http://192.168.1.10:8080');
  bool _busy = false;
  String? _error;
  String? _ok;

  String? _normalise(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return null;
    if (!v.startsWith('http://') && !v.startsWith('https://')) v = 'http://$v';
    final u = Uri.tryParse(v);
    if (u == null || u.host.isEmpty) return null;
    return v.replaceAll(RegExp(r'/+$'), '');
  }

  Future<void> _connect() async {
    final url = _normalise(_url.text);
    if (url == null) {
      setState(() => _error = 'Enter a valid address, e.g. 192.168.1.10:8080');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      final ctrl = ref.read(appControllerProvider.notifier);
      final info = await ctrl.probeServer(url);
      setState(
        () => _ok =
            'Connected to ${info.service.isEmpty ? 'server' : info.service} (${info.deploymentMode})',
      );
      await ctrl.setServerUrl(url);
    } on ApiOfflineException {
      setState(
        () => _error =
            'Cannot reach $url. Is the tablet on the resort Wi-Fi and the server running?',
      );
    } on ApiProblem catch (e) {
      setState(() => _error = 'Server answered with an error: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(32),
            children: [
              const Icon(Icons.dns_outlined, size: 64),
              const SizedBox(height: 16),
              Text(
                'Connect to the resort server',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter the address of the local server (ask IT if unsure). This is saved on the tablet.',
              ),
              const SizedBox(height: 24),
              TextField(
                key: const Key('server-url'),
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Server address',
                  prefixIcon: Icon(Icons.link),
                ),
                onSubmitted: (_) => _connect(),
              ),
              const SizedBox(height: 16),
              if (_error != null) InlineError(_error!),
              if (_ok != null)
                Text(
                  _ok!,
                  style: const TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('server-connect'),
                onPressed: _busy ? null : _connect,
                icon: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
