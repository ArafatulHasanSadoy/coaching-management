import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../app/bootstrap.dart';
import '../../app/lock_controller.dart';
import '../../core/strings.dart';
import '../../data/db/database.dart';

/// PIN gate shown over an already-open database.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submitPin() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final db = ref.read(databaseProvider);
      final users = await db.select(db.appUsers).get();
      final hasher = ref.read(pinHasherProvider);

      for (final user in users) {
        if (!user.isActive || user.deletedAt != null) continue;
        final ok = await hasher.verify(
          pin: _pin.text,
          hash: user.pinHash,
          salt: user.pinSalt,
        );
        if (ok) {
          ref.read(lockControllerProvider.notifier).unlockAs(user);
          return;
        }
      }
      if (mounted) setState(() => _error = Strings.wrongPin);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _pin.clear();
      }
    }
  }

  Future<void> _submitBiometric() async {
    final auth = LocalAuthentication();
    try {
      if (!await auth.canCheckBiometrics) return;
      final ok = await auth.authenticate(
        localizedReason: Strings.unlockReason,
        // The system prompt can background the app, which would otherwise trip
        // the lock-on-background observer and cancel the very unlock in flight.
        persistAcrossBackgrounding: true,
      );
      if (ok) ref.read(lockControllerProvider.notifier).unlock();
    } catch (_) {
      // Biometrics are a convenience; the PIN path is always available.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline,
                    size: 44, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(Strings.enterPin, style: theme.textTheme.titleLarge),
                const SizedBox(height: 20),
                TextField(
                  controller: _pin,
                  obscureText: true,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  onSubmitted: (_) => _submitPin(),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: TextStyle(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _submitPin,
                  child: const Text('Unlock'),
                ),
                TextButton.icon(
                  onPressed: _submitBiometric,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text(Strings.unlockWithBiometrics),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when startup cannot continue. States what happened, why, and the one
/// action that helps — rather than an error code.
class BlockedScreen extends StatelessWidget {
  const BlockedScreen({required this.state, super.key});

  final BootstrapBlocked state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline,
                    size: 40, color: theme.colorScheme.error),
                const SizedBox(height: 14),
                Text(state.title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 10),
                Text(state.body, style: theme.textTheme.bodyMedium),
                if (state.canRestore) ...[
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Restore arrives with the backup screen.'),
                        ),
                      );
                    },
                    icon: const Icon(Icons.settings_backup_restore),
                    label: const Text(Strings.restoreBackup),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Re-exported so the blocked screen can name the exception types it explains.
typedef LockedFailure = DatabaseLockedException;
