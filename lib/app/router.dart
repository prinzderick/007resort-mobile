import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/config/app_config.dart';
import '../core/device/device_mode.dart';
import '../core/state/app_state.dart';
import '../features/attendant/attendant_home.dart';
import '../features/attendant/menu_screen.dart';
import '../features/auth/checkout_screen.dart';
import '../features/auth/lock_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/bootstrap/enrol_screen.dart';
import '../features/bootstrap/setup_screen.dart';
import '../features/bootstrap/unresolved_screen.dart';
import '../features/collection/my_cash_screen.dart';
import '../features/sports/entrance_screen.dart';
import '../features/sports/store_screen.dart';
import '../features/supervisor/supervisor_home.dart';

abstract final class Routes {
  static const setup = '/setup';
  static const enrol = '/enrol';
  static const unresolved = '/unresolved';
  static const login = '/login';
  static const locked = '/locked';
  static const checkout = '/checkout';
  static const attendant = '/attendant';
  static const menu = '/attendant/menu';
  static const cash = '/attendant/cash';
  static const supervisor = '/supervisor';
  static const entrance = '/sports/entrance';
  static const store = '/sports/store';
}

/// The single place that decides which screen family a device/staff/session
/// combination may see. Pure function => unit-testable.
String baseRouteFor(AppState s, AppConfig config) {
  if (!config.useMock && s.serverUrl == null) return Routes.setup;
  if (s.device == null) return Routes.enrol;
  if (s.session == null) return Routes.login;
  if (s.locked) return Routes.locked;
  return switch (s.mode) {
    DeviceMode.unregistered => Routes.unresolved,
    DeviceMode.attendant =>
      s.checkout == null ? Routes.checkout : Routes.attendant,
    DeviceMode.supervisor => Routes.supervisor,
    DeviceMode.sportsEntrance => Routes.entrance,
    DeviceMode.sportsStore => Routes.store,
  };
}

/// Notifies go_router when app state changes so `redirect` re-runs.
class _RouterRefresh extends ChangeNotifier {
  void poke() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh();
  ref.listen<AppState>(appControllerProvider, (_, _) => refresh.poke());
  ref.onDispose(refresh.dispose);
  final config = ref.read(appConfigProvider);

  return GoRouter(
    initialLocation: baseRouteFor(ref.read(appControllerProvider), config),
    refreshListenable: refresh,
    redirect: (context, state) {
      final base = baseRouteFor(ref.read(appControllerProvider), config);
      final loc = state.matchedLocation;
      if (loc == base || loc.startsWith('$base/')) return null;
      return base;
    },
    routes: [
      GoRoute(path: Routes.setup, builder: (_, _) => const SetupScreen()),
      GoRoute(path: Routes.enrol, builder: (_, _) => const EnrolScreen()),
      GoRoute(
        path: Routes.unresolved,
        builder: (_, _) => const UnresolvedScreen(),
      ),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.locked, builder: (_, _) => const LockScreen()),
      GoRoute(path: Routes.checkout, builder: (_, _) => const CheckoutScreen()),
      GoRoute(
        path: Routes.attendant,
        builder: (_, _) => const AttendantHome(),
        routes: [
          GoRoute(path: 'menu', builder: (_, _) => const MenuScreen()),
          GoRoute(path: 'cash', builder: (_, _) => const MyCashScreen()),
        ],
      ),
      GoRoute(
        path: Routes.supervisor,
        builder: (_, _) => const SupervisorHome(),
      ),
      GoRoute(path: Routes.entrance, builder: (_, _) => const EntranceScreen()),
      GoRoute(path: Routes.store, builder: (_, _) => const StoreScreen()),
    ],
  );
});
