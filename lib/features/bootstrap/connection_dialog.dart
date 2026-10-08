import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/r007_api.dart';
import '../../core/state/app_state.dart';
import '../shared/widgets.dart';

/// Wraps a title so that tapping it 7 times (each within 2 s of the last) opens
/// the hidden Connection dialog. Staff never see a hint that it exists.
class HiddenConnectionTap extends ConsumerStatefulWidget {
  const HiddenConnectionTap({required this.child, super.key});
  final Widget child;
  @override
  ConsumerState<HiddenConnectionTap> createState() =>
      _HiddenConnectionTapState();
}

class _HiddenConnectionTapState extends ConsumerState<HiddenConnectionTap> {
  int _taps = 0;
  Timer? _reset;

  void _tap() {
    _reset?.cancel();
    _taps++;
    if (_taps >= 7) {
      _taps = 0;
      unawaited(showConnectionDialog(context));
      return;
    }
    _reset = Timer(const Duration(seconds: 2), () => _taps = 0);
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: _tap,
    child: widget.child,
  );
}

Future<void> showConnectionDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _ConnectionDialog(),
);

class _ConnectionDialog extends ConsumerStatefulWidget {
  const _ConnectionDialog();
  @override
  ConsumerState<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends ConsumerState<_ConnectionDialog> {
  final _pin = TextEditingController();
  final _url = TextEditingController();
  bool _unlocked = false;
  bool _busy = false;
  String? _error;
  List<String> _known = const [];

  @override
  void initState() {
    super.initState();
    _unlocked = ref.read(appConfigProvider).connectionPin.isEmpty;
    unawaited(_loadKnown());
  }

  Future<void> _loadKnown() async {
    final k = await ref.read(appControllerProvider.notifier).knownServers();
    if (mounted) setState(() => _known = k);
  }

  String? _normalise(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return null;
    if (!v.startsWith('http://') && !v.startsWith('https://')) v = 'http://$v';
    final u = Uri.tryParse(v);
    if (u == null || u.host.isEmpty) return null;
    return v.replaceAll(RegExp(r'/+$'), '');
  }

  Future<void> _switchTo(String raw) async {
    final url = _normalise(raw);
    if (url == null) {
      setState(() => _error = 'Enter a valid server address.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ctrl = ref.read(appControllerProvider.notifier);
    try {
      await ctrl.probeServer(url);
      await ctrl.switchServer(url);
      if (mounted) Navigator.of(context).pop();
    } on ApiOfflineException {
      setState(() => _error = 'Cannot reach $url from this tablet.');
    } on ApiProblem catch (e) {
      setState(
        () => _error = 'That server answered with an error: ${e.message}',
      );
    } on StateError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(appConfigProvider);
    final current = ref.watch(serverUrlProvider);
    final picks = <String, String>{
      if (cfg.onlineUrl.isNotEmpty) 'Online': cfg.onlineUrl,
      if (cfg.localUrl.isNotEmpty) 'Local': cfg.localUrl,
    };
    return AlertDialog(
      title: const Text('Connection'),
      content: SizedBox(
        width: 460,
        child: !_unlocked
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _pin,
                    obscureText: true,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Connection PIN',
                    ),
                    onSubmitted: (_) => _checkPin(cfg.connectionPin),
                  ),
                  if (_error != null) InlineError(_error!),
                ],
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Current: ${current ?? 'none'}'),
                    const SizedBox(height: 12),
                    if (picks.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final e in picks.entries)
                            ActionChip(
                              label: Text(e.key),
                              avatar: e.value == current
                                  ? const Icon(Icons.check, size: 18)
                                  : null,
                              onPressed: _busy
                                  ? null
                                  : () => _switchTo(e.value),
                            ),
                        ],
                      ),
                    for (final k in _known.where(
                      (k) => !picks.containsValue(k),
                    ))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(k),
                        trailing: k == current
                            ? const Icon(Icons.check)
                            : TextButton(
                                onPressed: _busy ? null : () => _switchTo(k),
                                child: const Text('Use'),
                              ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('connection-url'),
                      controller: _url,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Another server address',
                        prefixIcon: Icon(Icons.link),
                      ),
                      onSubmitted: _busy ? null : _switchTo,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Each server keeps its own enrolment and sign-in, so switching back later needs no re-enrolment.',
                      style: TextStyle(fontSize: 12),
                    ),
                    if (_error != null) InlineError(_error!),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (!_unlocked)
          FilledButton(
            onPressed: () => _checkPin(cfg.connectionPin),
            child: const Text('Unlock'),
          )
        else
          FilledButton(
            onPressed: _busy ? null : () => _switchTo(_url.text),
            child: const Text('Switch'),
          ),
      ],
    );
  }

  void _checkPin(String expected) {
    if (_pin.text == expected) {
      setState(() {
        _unlocked = true;
        _error = null;
      });
    } else {
      setState(() => _error = 'Wrong PIN.');
    }
  }
}
