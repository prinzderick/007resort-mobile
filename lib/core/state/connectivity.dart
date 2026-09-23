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
    if (ref.read(timersEnabledProvider)) _schedule();
    return const ConnState();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(
      state.online ? const Duration(seconds: 12) : const Duration(seconds: 4),
      () async {
        await probe();
        _schedule();
      },
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
    if (state.checking) return;
    state = state.copyWith(checking: true);
    try {
      await ref.read(apiProvider).systemInfo();
      state = state.copyWith(checking: false);
      reportOnline();
      // Even when never offline, flush anything left in the queue.
      if (ref.read(outboxProvider).hasPending) {
        unawaited(ref.read(outboxProvider.notifier).drain());
      }
    } on ApiOfflineException {
      state = state.copyWith(checking: false, online: false);
    } on Object {
      // Server answered with an error => reachable.
      state = state.copyWith(checking: false);
      reportOnline();
    }
  }
}
