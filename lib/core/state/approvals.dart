import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/r007_api.dart';
import '../models/models.dart';
import 'app_state.dart';
import 'board.dart';
import 'connectivity.dart';

class ApprovalsState {
  const ApprovalsState({
    this.pending = const [],
    this.loading = false,
    this.error,
    this.stale = false,
  });
  final List<Approval> pending;
  final bool loading;
  final String? error;
  final bool stale;
}

final approvalsProvider = NotifierProvider<ApprovalsController, ApprovalsState>(
  ApprovalsController.new,
);

/// Supervisor queue (`GET /approvals?scope=approvable`). Decisions are always
/// live: never queued offline (contract: approvals are not queueable).
class ApprovalsController extends Notifier<ApprovalsState> {
  bool _disposed = false;

  @override
  ApprovalsState build() {
    ref.onDispose(() => _disposed = true);
    ref.listen(
      boardProvider.select((s) => s.revision),
      (_, _) => unawaited(refresh()),
    );
    scheduleMicrotask(refresh);
    return const ApprovalsState(loading: true);
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final facilityId = ref.read(appControllerProvider).facilityId;
    try {
      final list = await ref
          .read(apiProvider)
          .listApprovals(
            scope: 'approvable',
            status: 'PENDING',
            facilityId: facilityId,
          );
      if (_disposed) return;
      state = ApprovalsState(pending: list);
    } on ApiOfflineException {
      if (_disposed) return;
      ref.read(connectivityProvider.notifier).reportOffline();
      state = ApprovalsState(pending: state.pending, stale: true);
    } on ApiProblem catch (e) {
      if (_disposed) return;
      state = ApprovalsState(pending: state.pending, error: e.message);
    }
  }

  /// Approve/reject with a supervisor PIN step-up. Throws on failure.
  Future<void> decide(
    Approval a, {
    required bool approve,
    String? note,
    required String pin,
  }) async {
    final api = ref.read(apiProvider);
    final me = ref.read(appControllerProvider).staff;
    final step = await api.stepUp(
      // The server identifies the approver by staff number + PIN.
      identifier: me?.staffNumber,
      secret: pin,
      credentialType: 'PIN',
      permission: a.permission,
      entityType: a.entityType,
      entityId: a.entityId,
    );
    await api.decideApproval(
      a.id,
      approve: approve,
      note: note,
      stepUpToken: step.token,
      idempotencyKey: newId(),
    );
    await refresh();
    unawaited(ref.read(boardProvider.notifier).refresh(silent: true));
  }
}
