import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/bootstrap.dart';
import 'app/lock_controller.dart';
import 'core/strings.dart';
import 'features/home/home_screen.dart';
import 'features/lock/lock_screen.dart';
import 'features/setup/setup_wizard.dart';
import 'features/setup/welcome_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: CoachingOpsApp()));
}

class CoachingOpsApp extends StatelessWidget {
  const CoachingOpsApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: Strings.appName,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF1B5E20),
          useMaterial3: true,
        ),
        home: const LockOnBackground(child: _Root()),
      );
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bootstrap = ref.watch(bootstrapProvider);

    return bootstrap.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not start: $error'),
          ),
        ),
      ),
      data: (state) => switch (state) {
        NeedsFirstRun() => const WelcomeScreen(),
        BootstrapBlocked() => BlockedScreen(state: state),
        // The wizard sits inside the unlocked branch on purpose: the database
        // is already open and encrypted at this point, and a half-configured
        // centre should still be behind the PIN.
        BootstrapReady(setupComplete: false) => ref.watch(lockControllerProvider)
            ? const LockScreen()
            : const SetupWizard(),
        BootstrapReady() => ref.watch(lockControllerProvider)
            ? const LockScreen()
            : const HomeScreen(),
      },
    );
  }
}
