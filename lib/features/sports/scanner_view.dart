import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/mock/mock_seed.dart';
import '../../core/state/app_state.dart';

/// Builds the camera QR view. Overridden in tests (no camera there).
typedef ScannerBuilder =
    Widget Function(BuildContext context, void Function(String code) onCode);

final scannerBuilderProvider = Provider<ScannerBuilder>(
  (ref) =>
      (context, onCode) => CameraScanner(onCode: onCode),
);

/// Camera QR scanner (mobile_scanner). Ignores repeat reads of the same code
/// within 3 s so one physical scan is one server call.
class CameraScanner extends StatefulWidget {
  const CameraScanner({super.key, required this.onCode});
  final void Function(String code) onCode;
  @override
  State<CameraScanner> createState() => _CameraScannerState();
}

class _CameraScannerState extends State<CameraScanner> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  String? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              final v = capture.barcodes
                  .map((b) => b.rawValue)
                  .whereType<String>()
                  .firstOrNull;
              if (v == null || v.isEmpty) return;
              final now = DateTime.now();
              if (v == _last &&
                  now.difference(_lastAt) < const Duration(seconds: 3)) {
                return;
              }
              _last = v;
              _lastAt = now;
              widget.onCode(v);
            },
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Camera unavailable (${error.errorCode.name}). Use the code field below or a handheld scanner.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          const Center(child: _Reticle()),
        ],
      ),
    );
  }
}

class _Reticle extends StatelessWidget {
  const _Reticle();
  @override
  Widget build(BuildContext context) => Container(
    width: 240,
    height: 240,
    decoration: BoxDecoration(
      border: Border.all(color: Colors.white, width: 4),
      borderRadius: BorderRadius.circular(20),
    ),
  );
}

/// Manual entry: also works with keyboard-wedge / handheld scanners, which
/// type the code and press Enter. Autofocus keeps wedge input flowing.
class CodeEntry extends ConsumerStatefulWidget {
  const CodeEntry({
    super.key,
    required this.onCode,
    this.label = 'Scan or type QR code',
  });
  final void Function(String code) onCode;
  final String label;
  @override
  ConsumerState<CodeEntry> createState() => _CodeEntryState();
}

class _CodeEntryState extends ConsumerState<CodeEntry> {
  final _c = TextEditingController();

  void _submit() {
    final v = _c.text.trim();
    if (v.isEmpty) return;
    _c.clear();
    widget.onCode(v);
  }

  @override
  Widget build(BuildContext context) {
    final mock = ref.watch(appConfigProvider).useMock;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('code-field'),
                controller: _c,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: widget.label,
                  prefixIcon: const Icon(Icons.qr_code_2),
                ),
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              key: const Key('code-submit'),
              onPressed: _submit,
              child: const Text('Check'),
            ),
          ],
        ),
        if (mock) ...[
          const SizedBox(height: 10),
          const Text(
            'DEMO codes (tap to scan):',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final e in mockDemoCodes.entries)
                ActionChip(
                  key: Key('demo-${e.key}'),
                  label: Text(e.value),
                  onPressed: () => widget.onCode(e.key),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
