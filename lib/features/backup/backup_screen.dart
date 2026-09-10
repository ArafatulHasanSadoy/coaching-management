import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../setup/restore_screen.dart';

/// Backup and restore.
///
/// The app is offline and lives on one phone, so a backup that never leaves
/// that phone protects against almost nothing — a dropped handset takes the
/// records and the backups together. Writing the file is therefore only half
/// the job, and this screen pushes the second half: get a copy somewhere else.
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _busy = false;
  File? _lastArchive;
  String? _status;
  bool _failed = false;

  Future<void> _backup() async {
    setState(() {
      _busy = true;
      _status = null;
      _failed = false;
    });
    try {
      final state = ref.read(bootstrapProvider).value! as BootstrapReady;
      final archive = await ref.read(backupServiceProvider).create(
            db: state.database,
            destination: state.paths.backupDir,
            deviceId: state.deviceId,
            mediaDir: state.paths.mediaDir,
          );

      // Verify immediately. A backup that was never checked is a belief, not a
      // backup — and the moment to discover a problem is now, not during a
      // recovery.
      final passphrase =
          await ref.read(secretsStoreProvider).masterPassphrase() ?? '';
      final check = await ref
          .read(backupServiceProvider)
          .inspect(archiveFile: archive, passphrase: passphrase);

      setState(() {
        _lastArchive = check.canRestore ? archive : null;
        _failed = !check.canRestore;
        _status = check.canRestore
            ? 'Backed up and verified — ${(archive.lengthSync() / 1024).toStringAsFixed(0)} KB'
            : 'Backup failed verification:\n${check.problems.join('\n')}';
      });
    } catch (e) {
      setState(() {
        _failed = true;
        _status = 'Backup failed: $e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    final archive = _lastArchive;
    if (archive == null) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(archive.path)],
        subject: 'Coaching centre backup',
        text: 'Keep this file safe. Restoring it needs your master passphrase.',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: const SectionAppBar(section: Section.setup, title: 'Backup'),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            color: theme.colorScheme.errorContainer,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('A backup on this phone only is not a backup.'),
                  SizedBox(height: 6),
                  Text(
                    'If the phone is lost or broken, the records and the backups '
                    'go together. Send a copy to Drive, Telegram or a computer '
                    'after every backup.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _backup,
            icon: _busy
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.backup_outlined),
            label: const Text('Back up now'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 16),
            Card(
              color: _failed
                  ? theme.colorScheme.errorContainer
                  : theme.colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(_status!, style: theme.textTheme.bodySmall),
              ),
            ),
          ],
          if (_lastArchive != null) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _share,
              icon: const Icon(Icons.ios_share),
              label: const Text('Send a copy off this phone'),
            ),
          ],
          const SizedBox(height: 32),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.settings_backup_restore),
            title: const Text('Restore a backup'),
            subtitle: const Text('Replaces everything currently in the app'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RestoreScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
