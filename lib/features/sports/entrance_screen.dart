import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/state/app_state.dart';
import '../../core/state/sports.dart';
import 'scanner_view.dart';

/// Visual + haptic identity of each scan outcome. Colour, icon AND big text so
/// it is unmistakable in sunlight and to colour-blind staff.
class OutcomeStyle {
  const OutcomeStyle(this.color, this.icon, this.headline);
  final Color color;
  final IconData icon;
  final String headline;

  static OutcomeStyle of(ScanOutcome o) => switch (o) {
    ScanOutcome.valid => const OutcomeStyle(
      Color(0xFF1B7F3B),
      Icons.check_circle_outline,
      'VALID',
    ),
    ScanOutcome.used => const OutcomeStyle(
      Color(0xFFC62828),
      Icons.block,
      'ALREADY USED',
    ),
    ScanOutcome.expired => const OutcomeStyle(
      Color(0xFFE65100),
      Icons.timer_off_outlined,
      'EXPIRED',
    ),
    ScanOutcome.wrongFacility => const OutcomeStyle(
      Color(0xFF6A1B9A),
      Icons.wrong_location_outlined,
      'WRONG FACILITY',
    ),
    ScanOutcome.notYetValid => const OutcomeStyle(
      Color(0xFF1565C0),
      Icons.schedule,
      'NOT YET VALID',
    ),
    ScanOutcome.cancelled => const OutcomeStyle(
      Color(0xFF212121),
      Icons.cancel_outlined,
      'CANCELLED',
    ),
    ScanOutcome.pending => const OutcomeStyle(
      Color(0xFFF2A100),
      Icons.how_to_reg_outlined,
      'STAFF APPROVAL',
    ),
    ScanOutcome.unknown => const OutcomeStyle(
      Color(0xFF546E7A),
      Icons.help_outline,
      'NOT RECOGNISED',
    ),
  };
}

/// Sports Entrance: scan -> `redeem` -> ONE full-screen unmistakable result.
/// Never guesses: without a server answer it shows a connection error.
class EntranceScreen extends ConsumerStatefulWidget {
  const EntranceScreen({super.key});
  @override
  ConsumerState<EntranceScreen> createState() => _EntranceScreenState();
}

class _EntranceScreenState extends ConsumerState<EntranceScreen> {
  Timer? _auto;
  bool _showHistory = false;

  @override
  void dispose() {
    _auto?.cancel();
    super.dispose();
  }

  void _feedback(ScanOutcome o) {
    if (!ref.read(feedbackEnabledProvider)) return;
    if (o == ScanOutcome.valid) {
      unawaited(HapticFeedback.mediumImpact());
      unawaited(SystemSound.play(SystemSoundType.click));
    } else {
      unawaited(HapticFeedback.heavyImpact());
      unawaited(SystemSound.play(SystemSoundType.alert));
      Timer(const Duration(milliseconds: 250), HapticFeedback.heavyImpact);
    }
  }

  Future<void> _scan(String code) async {
    await ref.read(entranceProvider.notifier).scan(code);
    final s = ref.read(entranceProvider);
    if (s.result != null) {
      _feedback(s.result!.outcome);
      _auto?.cancel();
      if (s.result!.outcome == ScanOutcome.valid &&
          ref.read(timersEnabledProvider)) {
        _auto = Timer(
          const Duration(seconds: 5),
          () => ref.read(entranceProvider.notifier).reset(),
        );
      }
    } else if (s.connectionError != null) {
      _feedback(ScanOutcome.unknown);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(entranceProvider);
    final app = ref.watch(appControllerProvider);
    final build = ref.watch(scannerBuilderProvider);

    Widget body;
    if (s.busy) {
      body = const Center(
        child: CircularProgressIndicator(key: Key('scan-busy')),
      );
    } else if (s.result != null) {
      body = _ResultView(
        result: s.result!,
        onNext: () {
          _auto?.cancel();
          ref.read(entranceProvider.notifier).reset();
        },
      );
    } else if (s.connectionError != null) {
      body = _ConnectionErrorView(
        message: s.connectionError!,
        onRetry: () => _scan(s.lastCode ?? ''),
        onCancel: () => ref.read(entranceProvider.notifier).reset(),
      );
    } else {
      body = Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: AspectRatio(aspectRatio: 1, child: build(context, _scan)),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 4,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Point the camera at the QR code',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    CodeEntry(onCode: _scan),
                    const SizedBox(height: 16),
                    if (_showHistory || s.history.isNotEmpty)
                      _History(records: s.history),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final showAppBar = s.result == null && s.connectionError == null;
    return Scaffold(
      backgroundColor: s.result != null
          ? OutcomeStyle.of(s.result!.outcome).color
          : null,
      appBar: showAppBar
          ? AppBar(
              title: Text('Sports Entrance  -  ${app.facilityName ?? ''}'),
              actions: [
                Center(child: Text(app.staff?.name ?? '')),
                IconButton(
                  tooltip: 'History',
                  icon: const Icon(Icons.history),
                  onPressed: () => setState(() => _showHistory = !_showHistory),
                ),
                IconButton(
                  tooltip: 'Sign out',
                  icon: const Icon(Icons.logout),
                  onPressed: () =>
                      ref.read(appControllerProvider.notifier).logout(),
                ),
              ],
            )
          : null,
      body: body,
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.result, required this.onNext});
  final RedeemResult result;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final st = OutcomeStyle.of(result.outcome);
    const white = TextStyle(color: Colors.white);
    return InkWell(
      key: const Key('result-view'),
      onTap: onNext,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(st.icon, size: 180, color: Colors.white),
                const SizedBox(height: 12),
                Text(
                  st.headline,
                  key: const Key('result-headline'),
                  textAlign: TextAlign.center,
                  style: white.copyWith(
                    fontSize: 76,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 16),
                if (result.holderName != null)
                  Text(
                    result.holderName!,
                    style: white.copyWith(
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (result.itemName != null)
                  Text(result.itemName!, style: white.copyWith(fontSize: 24)),
                if (result.outcome == ScanOutcome.valid &&
                    result.remaining != null &&
                    result.remaining! > 0)
                  Text(
                    '${result.remaining} more entr${result.remaining == 1 ? 'y' : 'ies'} on this ticket',
                    style: white.copyWith(fontSize: 22),
                  ),
                if (result.message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      result.message!,
                      textAlign: TextAlign.center,
                      style: white.copyWith(fontSize: 24),
                    ),
                  ),
                if (result.validUntil != null &&
                    result.outcome != ScanOutcome.valid)
                  Text(
                    'Valid until ${_fmt(result.validUntil!)}',
                    style: white.copyWith(fontSize: 20),
                  ),
                if (result.validFrom != null &&
                    result.outcome == ScanOutcome.notYetValid)
                  Text(
                    'Valid from ${_fmt(result.validFrom!)}',
                    style: white.copyWith(fontSize: 20),
                  ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  key: const Key('next-scan'),
                  onPressed: onNext,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: st.color,
                    minimumSize: const Size(260, 72),
                  ),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text(
                    'Scan next',
                    style: TextStyle(fontSize: 24),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _fmt(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}

class _ConnectionErrorView extends StatelessWidget {
  const _ConnectionErrorView({
    required this.message,
    required this.onRetry,
    required this.onCancel,
  });
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('connection-error'),
      color: const Color(0xFFB71C1C),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off, size: 150, color: Colors.white),
                const SizedBox(height: 12),
                const Text(
                  'NO CONNECTION',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 64,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 24),
                ),
                const SizedBox(height: 28),
                Wrap(
                  spacing: 16,
                  children: [
                    FilledButton(
                      key: const Key('conn-retry'),
                      onPressed: onRetry,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFFB71C1C),
                        minimumSize: const Size(200, 64),
                      ),
                      child: const Text('Try again'),
                    ),
                    OutlinedButton(
                      key: const Key('conn-cancel'),
                      onPressed: onCancel,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white),
                        minimumSize: const Size(200, 64),
                      ),
                      child: const Text('Back to scanner'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.records});
  final List<ScanRecord> records;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) return const Text('No scans yet this session');
    String two(int n) => n.toString().padLeft(2, '0');
    return Column(
      key: const Key('scan-history'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Recent scans', style: Theme.of(context).textTheme.titleMedium),
        for (final r in records.take(12))
          ListTile(
            dense: true,
            leading: Icon(
              OutcomeStyle.of(r.outcome).icon,
              color: OutcomeStyle.of(r.outcome).color,
            ),
            title: Text(
              '${OutcomeStyle.of(r.outcome).headline}${r.holderName != null ? '  -  ${r.holderName}' : ''}',
            ),
            subtitle: Text(
              r.code,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(
              '${two(r.at.hour)}:${two(r.at.minute)}:${two(r.at.second)}',
            ),
          ),
      ],
    );
  }
}
