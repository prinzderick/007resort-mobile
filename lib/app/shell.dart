import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/device/device_mode.dart';
import '../core/mock/mock_api.dart';
import '../core/offline/offline_queue.dart';
import '../core/state/app_state.dart';
import '../core/state/connectivity.dart';
import '../core/state/outbox.dart';
import 'theme.dart';

/// App-wide chrome: connectivity/outbox banner, demo-mode strip and the
/// idle auto-lock listener.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.config, required this.child});
  final AppConfig config;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IdleGuard(
      seconds: config.idleLockSeconds,
      child: Material(
        child: Column(
          children: [
            if (config.useMock) const _DemoStrip(),
            const ConnectivityBanner(),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

/// Locks the tablet (PIN to resume) after [seconds] without touch input.
/// Sports tablets stay unlocked (scanning must never be interrupted).
class IdleGuard extends ConsumerStatefulWidget {
  const IdleGuard({super.key, required this.seconds, required this.child});
  final int seconds;
  final Widget child;

  @override
  ConsumerState<IdleGuard> createState() => _IdleGuardState();
}

class _IdleGuardState extends ConsumerState<IdleGuard> {
  Timer? _timer;

  void _reset() {
    _timer?.cancel();
    if (!ref.read(timersEnabledProvider)) return;
    final s = ref.read(appControllerProvider);
    final lockable =
        s.session != null &&
        !s.locked &&
        (s.mode == DeviceMode.attendant || s.mode == DeviceMode.supervisor);
    if (!lockable) return;
    _timer = Timer(
      Duration(seconds: widget.seconds),
      () => ref.read(appControllerProvider.notifier).lock(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appControllerProvider, (_, _) => _reset());
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _reset(),
      child: widget.child,
    );
  }
}

class _DemoStrip extends ConsumerStatefulWidget {
  const _DemoStrip();
  @override
  ConsumerState<_DemoStrip> createState() => _DemoStripState();
}

class _DemoStripState extends ConsumerState<_DemoStrip> {
  @override
  Widget build(BuildContext context) {
    final api = ref.watch(apiProvider);
    if (api is! MockR007Api) return const SizedBox.shrink();
    return Container(
      color: R007Colors.purple,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      height: 40,
      child: Row(
        children: [
          const Icon(Icons.science_outlined, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'DEMO MODE - built-in mock server',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Text(
            'Simulate Wi-Fi drop',
            style: TextStyle(color: Colors.white),
          ),
          Switch(
            key: const Key('mock-offline-switch'),
            value: api.offline,
            activeThumbColor: Colors.white,
            onChanged: (v) {
              api.setOffline(v);
              setState(() {});
              if (!v) {
                unawaited(ref.read(connectivityProvider.notifier).probe());
              }
            },
          ),
        ],
      ),
    );
  }
}

/// Persistent, unmissable connectivity + outbox status.
class ConnectivityBanner extends ConsumerWidget {
  const ConnectivityBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectivityProvider);
    final box = ref.watch(outboxProvider);
    final n = box.pending.length;

    Widget bar(
      Color color,
      IconData icon,
      String text, {
      Widget? trailing,
      Key? key,
    }) => Material(
      key: key,
      color: color,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );

    final bars = <Widget>[];
    if (!conn.online) {
      bars.add(
        bar(
          R007Colors.red,
          Icons.wifi_off,
          n > 0
              ? 'Reconnecting... $n action${n == 1 ? '' : 's'} waiting to be sent'
              : 'Reconnecting to the server... showing last known data',
          key: const Key('banner-offline'),
          trailing: TextButton(
            onPressed: () => ref.read(connectivityProvider.notifier).probe(),
            child: const Text(
              'Retry now',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
      );
    } else if (n > 0) {
      bars.add(
        bar(
          R007Colors.blue,
          Icons.cloud_upload_outlined,
          'Sending $n queued action${n == 1 ? '' : 's'}...',
          key: const Key('banner-sending'),
        ),
      );
    }
    if (box.blockReason != null) {
      bars.add(
        bar(
          R007Colors.orange,
          Icons.block,
          box.blockReason!,
          key: const Key('banner-blocked'),
        ),
      );
    }
    if (box.failed.isNotEmpty) {
      bars.add(
        bar(
          R007Colors.amber.withValues(alpha: 1),
          Icons.warning_amber_rounded,
          '${box.failed.length} action${box.failed.length == 1 ? ' was' : 's were'} rejected by the server',
          key: const Key('banner-failed'),
          trailing: TextButton(
            onPressed: () => showFailedOps(context, ref),
            child: const Text('Review', style: TextStyle(color: Colors.white)),
          ),
        ),
      );
    }
    if (bars.isEmpty) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: bars);
  }
}

Future<void> showFailedOps(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final failed = ref.watch(outboxProvider).failed;
        return AlertDialog(
          title: const Text('Actions the server rejected'),
          content: SizedBox(
            width: 460,
            child: failed.isEmpty
                ? const Text('Nothing to review.')
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final QueuedOp op in failed)
                        ListTile(
                          title: Text(_opLabel(op)),
                          subtitle: Text(op.error ?? 'Rejected'),
                          trailing: IconButton(
                            tooltip: 'Discard',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => ref
                                .read(outboxProvider.notifier)
                                .dismiss(op.id),
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [
            if (failed.isNotEmpty)
              TextButton(
                onPressed: () =>
                    ref.read(outboxProvider.notifier).clearFailed(),
                child: const Text('Discard all'),
              ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    ),
  );
}

String _opLabel(QueuedOp op) => switch (op.type) {
  OpType.createOrder => 'Create order',
  OpType.sendOrder => 'Send order',
  OpType.openTab => 'Open tab',
  OpType.openTable => 'Open table',
  _ => op.type,
};
