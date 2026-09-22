import 'package:flutter/material.dart';

/// Placeholder: Moving attendant (waiter) workflow. Orders are sent to the API; pricing and stock are decided server-side.
///
/// Phase 0 scaffolding only - no business logic lives in the client.
class AttendantScreen extends StatelessWidget {
  const AttendantScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Attendant')),
      body: const Center(child: Text('Attendant - coming soon')),
    );
  }
}
