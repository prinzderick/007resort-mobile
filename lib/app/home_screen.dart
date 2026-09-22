import 'package:flutter/material.dart';

import '../core/device/device_mode.dart';

/// Home placeholder. Shows the device mode resolved from the API.
///
/// Until device registration is implemented, every device is
/// [DeviceMode.unregistered].
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.mode});

  final DeviceMode mode;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Otueke')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tablet_android, size: 64),
            const SizedBox(height: 16),
            if (mode == DeviceMode.unregistered)
              Text('Device not registered', style: textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text('Mode: ${mode.label}', style: textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}
