import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../core/api/r007_api.dart';
import '../../core/models/models.dart';
import '../../core/util/money.dart';

/// Turns any thrown object into a message safe to show staff.
String describeError(Object e) {
  if (e is ApiOfflineException) return 'Cannot reach the server. Check Wi-Fi.';
  if (e is ApiProblem) {
    return switch (e.code) {
      'permission_denied' => 'You do not have permission to do that.',
      'device_revoked' => 'This tablet has been revoked. Contact IT.',
      'account_locked' =>
        'Account locked after too many attempts. Ask a supervisor.',
      'rate_limited' => 'Too many attempts. Wait a moment.',
      _ => e.message,
    };
  }
  return 'Something went wrong. Please try again.';
}

Color orderStatusColor(String status) => switch (status) {
  OrderStatus.draft => R007Colors.grey,
  OrderStatus.sent => R007Colors.blue,
  OrderStatus.inPreparation => R007Colors.amber,
  OrderStatus.ready => R007Colors.green,
  OrderStatus.served => R007Colors.greenDark,
  OrderStatus.settled => R007Colors.grey,
  OrderStatus.voided => R007Colors.red,
  OrderStatus.pendingApproval => R007Colors.purple,
  _ => R007Colors.grey,
};

String statusLabel(String s) => s.replaceAll('_', ' ');

/// Coloured status chip with text (never colour alone).
class StatusPill extends StatelessWidget {
  const StatusPill(this.label, this.color, {super.key, this.icon});
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class OrderStatusPill extends StatelessWidget {
  const OrderStatusPill(this.order, {super.key});
  final Order order;
  @override
  Widget build(BuildContext context) {
    if (order.pendingConfirmation) {
      return const StatusPill(
        'PENDING CONFIRMATION',
        R007Colors.orange,
        icon: Icons.cloud_upload_outlined,
      );
    }
    return StatusPill(
      statusLabel(order.status),
      orderStatusColor(order.status),
    );
  }
}

Color lineStatusColor(String s) => switch (s) {
  LineStatus.ready => R007Colors.green,
  LineStatus.dispensed => R007Colors.greenDark,
  LineStatus.accepted || LineStatus.inProgress => R007Colors.amber,
  LineStatus.voided || LineStatus.removed => R007Colors.red,
  LineStatus.routed || LineStatus.locked => R007Colors.blue,
  _ => R007Colors.grey,
};

class InlineError extends StatelessWidget {
  const InlineError(this.message, {super.key, this.onRetry});
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState(this.icon, this.message, {super.key});
  final IconData icon;
  final String message;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Numeric PIN pad (large keys) with optional hardware/wedge text entry.
class PinPad extends StatelessWidget {
  const PinPad({
    super.key,
    required this.controller,
    this.onSubmit,
    this.maxLength = 8,
  });
  final TextEditingController controller;
  final VoidCallback? onSubmit;
  final int maxLength;

  void _tap(String d) {
    if (controller.text.length < maxLength) {
      controller.text += d;
    }
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap, IconData? icon}) => Padding(
      padding: const EdgeInsets.all(5),
      child: SizedBox(
        width: 88,
        height: 64,
        child: OutlinedButton(
          key: Key('pin-$label'),
          onPressed: onTap ?? () => _tap(label),
          child: icon != null
              ? Icon(icon)
              : Text(label, style: const TextStyle(fontSize: 26)),
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [for (final d in row) key(d)],
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            key('C', onTap: controller.clear, icon: Icons.clear),
            key('0'),
            key(
              '<',
              icon: Icons.backspace_outlined,
              onTap: () {
                final t = controller.text;
                if (t.isNotEmpty) {
                  controller.text = t.substring(0, t.length - 1);
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Supervisor authorisation (PIN step-up). Returns the PIN and identifier or null.
class StepUpCredentials {
  const StepUpCredentials({
    this.identifier,
    required this.secret,
    this.credentialType = 'PIN',
  });
  final String? identifier;
  final String secret;
  final String credentialType;
}

/// Asks for a supervisor credential. When [selfAuth] is true the current
/// staff member re-enters their OWN PIN (no identifier); otherwise another
/// supervisor identifies themselves (staff number / username + PIN) or taps NFC.
Future<StepUpCredentials?> askStepUp(
  BuildContext context, {
  required String title,
  bool selfAuth = false,
}) {
  final id = TextEditingController();
  final pin = TextEditingController();
  return showDialog<StepUpCredentials>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!selfAuth) ...[
              TextField(
                key: const Key('stepup-identifier'),
                controller: id,
                decoration: const InputDecoration(
                  labelText: 'Supervisor staff number',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const Key('stepup-pin'),
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                labelText: selfAuth ? 'Your PIN' : 'Supervisor PIN',
                prefixIcon: const Icon(Icons.lock_outline),
              ),
              onSubmitted: (_) => Navigator.of(ctx).pop(
                StepUpCredentials(
                  identifier: selfAuth ? null : id.text.trim(),
                  secret: pin.text,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('stepup-confirm'),
          onPressed: () => Navigator.of(ctx).pop(
            StepUpCredentials(
              identifier: selfAuth ? null : id.text.trim(),
              secret: pin.text,
            ),
          ),
          child: const Text('Authorise'),
        ),
      ],
    ),
  );
}

/// Reason prompt used for void / discount / reject. Returns null if cancelled.
Future<String?> askReason(
  BuildContext context, {
  required String title,
  String label = 'Reason',
  String? confirm,
}) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        child: TextField(
          key: const Key('reason-field'),
          controller: c,
          autofocus: true,
          maxLines: 2,
          decoration: InputDecoration(labelText: label),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('reason-confirm'),
          onPressed: () {
            if (c.text.trim().length < 3) return;
            Navigator.of(ctx).pop(c.text.trim());
          },
          child: Text(confirm ?? 'Confirm'),
        ),
      ],
    ),
  );
}

void toast(BuildContext context, String message, {bool error = false}) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(
    SnackBar(
      content: Text(message, style: const TextStyle(fontSize: 16)),
      backgroundColor: error ? R007Colors.red : null,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
    ),
  );
}

/// Currency display of a server-provided decimal string.
String money(String? v, {String currency = 'NGN'}) =>
    v == null ? '-' : Money.format(v, currency: currency);
