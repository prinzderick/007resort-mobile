import 'package:flutter/material.dart';

/// Placeholder: Scan QR -> API validates -> show VALID, USED, EXPIRED, WRONG FACILITY, NOT YET VALID or CANCELLED.
///
/// Phase 0 scaffolding only - no business logic lives in the client.
class SportsEntranceScreen extends StatelessWidget {
  const SportsEntranceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sports entrance')),
      body: const Center(child: Text('Sports entrance - coming soon')),
    );
  }
}
