import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

import '../app/app_controller.dart';
import '../app/app_scope.dart';
import 'home_screen.dart';
import 'lock_screen.dart';
import 'setup_screen.dart';

/// The root route. Shows setup, the lock screen or the vault. Every other
/// screen is pushed above it and is closed when the vault locks.
class Gate extends StatelessWidget {
  const Gate({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context).controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => switch (controller.status) {
        AppStatus.loading => const UiScaffold(body: Center(child: UiSpinner(size: 28))),
        AppStatus.setup => const SetupScreen(),
        AppStatus.locked => const LockScreen(),
        AppStatus.unlocked => const HomeScreen(),
      },
    );
  }
}
