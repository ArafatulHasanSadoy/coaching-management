import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../app/lock_controller.dart';
import '../../core/sections.dart';
import '../../data/backup/backup_service.dart';

/// Restores a backup onto this device.
///
/// Nothing is overwritten until the archive has been inspected and the
/// passphrase proved to open it, and the user sees what the archive contains
/// before committing — restoring the wrong file over a live centre is the most
/// destructive thing this app can do.
class RestoreScreen extends ConsumerStatefulWidget {
  const RestoreScreen({super.key});

  @override
  ConsumerState<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends ConsumerState<RestoreScreen> {
  final _passphrase = TextEditingController();
  File? _archive;
  BackupInspection? _inspection;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    // file_picker 12 exposes these as statics, with pickFile for the
    // single-selection case.
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Choose a backup file',
      type: FileType.any,
    );
    final path = picked?.path;
    if (path == null) return;
    setState(() {
      _archive = File(path);
      _inspection = null;
      _error = null;
    });
  }

  Future<void> _check() async {
    if (_archive == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(backupServiceProvider).inspect(
            archiveFile: _archive!,
            passphrase: _passphrase.text,
          );
      setState(() => _inspection = result);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    try {
      final secrets = ref.read(secretsStoreProvider);
      final paths = await ref.read(appPathsProvider.future);

      await ref.read(backupServiceProvider).restore(
            archiveFile: _archive!,
            passphrase: _passphrase.text,
            targetDbFile: paths.databaseFile,
            targetMediaDir: paths.mediaDir,
          );

      // Only cached once the restore succeeded — a cached passphrase that opens
      // nothing would lock the owner out on the next launch.
      await secrets.cacheMasterPassphrase(_passphrase.text);

      ref.read(lockControllerProvider.notifier).unlock();
      ref.invalidate(bootstrapProvider);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inspection = _inspection;

    return Scaffold(
      appBar: const SectionAppBar(section: Section.setup, title: 'Restore a backup'),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickFile,
            icon: const Icon(Icons.folder_open),
            label: Text(_archive == null
                ? 'Choose backup file'
                : _archive!.path.split('/').last),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _passphrase,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Master passphrase',
              helperText: 'The passphrase from the phone that made this backup.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed:
                _busy || _archive == null || _passphrase.text.isEmpty ? null : _check,
            child: const Text('Check this backup'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          if (inspection != null) ...[
            const SizedBox(height: 20),
            Card(
              color: inspection.canRestore
                  ? theme.colorScheme.secondaryContainer
                  : theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      inspection.canRestore
                          ? 'This backup can be restored'
                          : 'This backup cannot be restored',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    if (inspection.manifest case final m?) ...[
                      Text('Made ${_when(m.createdAt)}'),
                      Text('${m.mediaFileCount} photo(s) and documents'),
                    ],
                    for (final problem in inspection.problems)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('• $problem'),
                      ),
                  ],
                ),
              ),
            ),
            if (inspection.canRestore) ...[
              const SizedBox(height: 18),
              Text(
                'Restoring replaces everything currently in the app. The '
                'database being replaced is kept aside first, so this can be '
                'undone.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _restore,
                icon: const Icon(Icons.settings_backup_restore),
                label: const Text('Restore now'),
              ),
            ],
          ],
        ],
      ),
    );
  }

  static String _when(DateTime t) {
    final days = DateTime.now().difference(t).inDays;
    if (days == 0) return 'today';
    if (days == 1) return 'yesterday';
    return '$days days ago';
  }
}
