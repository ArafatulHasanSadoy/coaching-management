import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../app/lock_controller.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';

/// First launch: choose the master passphrase and a PIN.
///
/// The passphrase screen is blunt about consequences on purpose. It is the only
/// thing that can open a backup on a replacement phone, and an owner who does
/// not write it down has backups that cannot be restored — which they will
/// discover at the worst possible moment.
class FirstRunScreen extends ConsumerStatefulWidget {
  const FirstRunScreen({super.key});

  @override
  ConsumerState<FirstRunScreen> createState() => _FirstRunScreenState();
}

class _FirstRunScreenState extends ConsumerState<FirstRunScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  final _pin = TextEditingController();
  bool _acknowledged = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || !_acknowledged) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final secrets = ref.read(secretsStoreProvider);
      final paths = await ref.read(appPathsProvider.future);
      final deviceId = await secrets.deviceId();
      final passphrase = _passphrase.text;

      final db = await AppDatabase.open(
        file: paths.databaseFile,
        encryptionKey: passphrase,
      );

      final pin = await ref.read(pinHasherProvider).hash(_pin.text);
      final owner = await db.into(db.appUsers).insertReturning(
            AppUsersCompanion.insert(
              name: 'Owner',
              role: UserRole.owner,
              pinHash: pin.hash,
              pinSalt: pin.salt,
              deviceId: deviceId,
            ),
          );

      // Creating the owner account is the first thing the trail should show.
      // Deliberately records no credential material — only that it happened.
      await db.recordChange(
        entity: 'app_users',
        entityId: owner.id,
        op: ChangeOp.insert,
        deviceId: deviceId,
        action: 'owner_created',
        after: {'name': owner.name, 'role': owner.role.name},
        userId: owner.id,
      );
      await db.close();

      // Cached only after the database has been proved to open with it, so a
      // failure here never leaves a passphrase stored that opens nothing.
      await secrets.cacheMasterPassphrase(passphrase);

      ref.read(lockControllerProvider.notifier).unlock();
      ref.invalidate(bootstrapProvider);

      // This screen was pushed on top of the welcome screen, so invalidating
      // the provider only changes what is rendered *underneath* it. Without
      // popping, setup succeeds and the user is left looking at the form they
      // just completed.
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: const SectionAppBar(section: Section.setup, title: 'Set up this device'),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Master passphrase', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text(
              'This encrypts everything stored on this phone, and it is the only '
              'thing that can open a backup on a new phone.',
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _passphrase,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Master passphrase',
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.length < 10)
                  ? 'Use at least 10 characters.'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _confirm,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Type it again',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  v != _passphrase.text ? 'The two do not match.' : null,
            ),
            const SizedBox(height: 16),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Write this down somewhere other than this phone.',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Nobody can recover it for you. If it is lost, every '
                      'backup you have ever made becomes unreadable.',
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _acknowledged,
                      onChanged: (v) =>
                          setState(() => _acknowledged = v ?? false),
                      title: const Text('I have written it down'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('Unlock PIN', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text(
              'Used for day-to-day unlocking so you do not type the passphrase '
              'every time.',
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'PIN (4–6 digits)',
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                if (v == null || v.length < 4) return 'Use at least 4 digits.';
                if (int.tryParse(v) == null) return 'Digits only.';
                return null;
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy || !_acknowledged ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }
}
