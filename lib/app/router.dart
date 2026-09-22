import 'package:flutter/material.dart';

import '../core/device/device_mode.dart';
import '../features/attendant/attendant_screen.dart';
import '../features/device_checkout/device_checkout_screen.dart';
import '../features/sports_entrance/sports_entrance_screen.dart';
import '../features/sports_store/sports_store_screen.dart';
import '../features/supervisor/supervisor_screen.dart';
import 'home_screen.dart';

/// Placeholder router.
///
/// Phase 0 uses plain named routes. A routing package may be adopted after
/// the architecture review; keep route names stable in the meantime.
abstract final class AppRouter {
  static const String home = '/';
  static const String deviceCheckout = '/device-checkout';

  static Route<void> onGenerateRoute(RouteSettings settings) {
    final Widget page = switch (settings.name) {
      deviceCheckout => const DeviceCheckoutScreen(),
      _ => const HomeScreen(mode: DeviceMode.unregistered),
    };
    return MaterialPageRoute<void>(builder: (_) => page, settings: settings);
  }

  /// Returns the root screen for a device mode resolved from the API.
  static Widget screenForMode(DeviceMode mode) => switch (mode) {
    DeviceMode.unregistered => const HomeScreen(mode: DeviceMode.unregistered),
    DeviceMode.attendant => const AttendantScreen(),
    DeviceMode.supervisor => const SupervisorScreen(),
    DeviceMode.sportsEntrance => const SportsEntranceScreen(),
    DeviceMode.sportsStore => const SportsStoreScreen(),
  };
}
