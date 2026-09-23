import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/r007_api.dart';
import 'app_state.dart';
import 'outbox.dart';

class ConnState {
  const ConnState({this.online = true, this.checking = false, this.lastOkAt});
  final bool online;
  final bool checking;
  final DateTime? lastOkAt;
  ConnState copyWith({bool? online, bool? checking, DateTime? lastOkAt}) =>
      ConnState(
        online: online ?? this.online,
        checking: checking ?? this.checking,
        lastOkAt: lastOkAt ?? this.lastOkAt,
      );
}

/// Tracks reachability of the local API. Requests report failures/successes
/// via [reportOffline]/[reportOnline]; a light `/system/info` probe (faster
/// while offline) detects recovery and triggers the outbox drain.
final connectivityProvider =
    NotifierProvider<ConnectivityController, ConnState>(
      ConnectivityController.new,
    );

class ConnectivityController extends Notifier<ConnState> {
  Timer? _timer;

  @override
  ConnState build() {
    ref.onDispose(() => _timer?.cancel());
    if (ref.read(timersEnabledProvider)) {
      // NB: never read `state` inside build(); schedule via a timer callback.
      _timer = Timer(const Duration(seconds: 12), _tick);
    }
    return const ConnState();
  }

  Future<void> _tick() async {
    await probe();
    _timer?.cancel();
    _timer = Timer(
      state.online ? const Duration(seconds: 12) : const Duration(seconds: 4),
      _tick,
    );
  }

  void reportOffline() {
    if (state.online) state = state.copyWith(online: false);
  }

  void reportOnline() {
    final was = state.online;
    state = state.copyWith(online: true, lastOkAt: DateTime.now().toUtc());
    if (!was) unawaited(ref.read(outboxProvider.notifier).drain());
  }

  Future<void> probe() async {
    if (state.checking) {
      return;
    }
    // Nothing to probe before the server address is configured.
    if (!ref.read(appConfigProvider).useMock &&
        ref.read(serverUrlProvider) == null) {
      if (!state.online) state = state.copyWith(online: true);
      return;
    }
    state = state.copyWith(checking: true);
    try {
      await ref.read(apiProvider).systemInfo();
      _markReachable();
    } on ApiOfflineException {
      state = state.copyWith(checking: false, online: false);
      return;
    } on Object {
      // Server answered with an error => it is reachable.
      _markReachable();
    }
    // Reachable: flush anything waiting (in order) before screens reload.
    if (ref.read(outboxProvider).hasPending) {
      await ref.read(outboxProvider.notifier).drain();
    }
  }

  void _markReachable() => state = state.copyWith(
    checking: false,
    online: true,
    lastOkAt: DateTime.now().toUtc(),
  );
}
