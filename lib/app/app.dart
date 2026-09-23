import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/state/app_state.dart';
import 'router.dart';
import 'shell.dart';
import 'theme.dart';

/// Root widget of the 007 Resort & Spa tablet app.
///
/// ONE app build serves all 18 tablets. The UI is driven by the enrolled
/// device (kind + home facility) and the signed-in staff's permissions; it is
/// never hardcoded per build.
class R007App extends ConsumerWidget {
  const R007App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final config = ref.watch(appConfigProvider);
    return MaterialApp.router(
      title: '007 Resort & Spa',
      debugShowCheckedModeBanner: false,
      theme: buildR007Theme(),
      darkTheme: buildR007Theme(brightness: Brightness.dark),
      themeMode: ThemeMode.light,
      routerConfig: router,
      builder: (context, child) =>
          AppShell(config: config, child: child ?? const SizedBox.shrink()),
    );
  }
}
