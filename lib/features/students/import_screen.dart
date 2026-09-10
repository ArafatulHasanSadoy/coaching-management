import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/students/csv_import.dart';

/// Imports a centre's existing student register.
///
/// The machine work takes milliseconds; what takes the time is the owner
/// checking that each column landed on the right field. So the screen spends
/// its space on exactly that — the guessed mapping shown plainly and correctable
/// in one tap — rather than on progress bars.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  File? _file;
  ImportPreview? _preview;
  String? _batchId;
  ImportOutcome? _outcome;
  bool _busy = false;
  String? _error;

  Future<void> _pick() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Choose your student register',
      type: FileType.any,
    );
    final path = picked?.path;
    if (path == null) return;
    setState(() {
      _file = File(path);
      _preview = null;
      _outcome = null;
      _error = null;
    });
    await _reparse();
  }

  Future<void> _reparse({Map<ImportField, int>? mapping}) async {
    if (_file == null) return;
    setState(() => _busy = true);
    try {
      final preview = await ref.read(csvImportProvider).preview(
            file: _file!,
            db: ref.read(databaseProvider),
            overrideMapping: mapping,
          );
      setState(() => _preview = preview);
    } catch (e) {
      setState(() => _error = 'Could not read that file: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final session = await ref.read(activeSessionProvider.future);
      final outcome = await ref.read(csvImportProvider).commit(
            db: ref.read(databaseProvider),
            preview: _preview!,
            batchId: _batchId!,
            sessionId: session!.id,
            deviceId: (ref.read(bootstrapProvider).value! as BootstrapReady)
                .deviceId,
            sourceName: _file!.path.split('/').last,
          );
      setState(() => _outcome = outcome);
    } catch (e) {
      setState(() => _error = 'Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _preview;
    final outcome = _outcome;

    return Scaffold(
      appBar: const SectionAppBar(section: Section.students, title: 'Import a register'),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (outcome != null) ...[
            _Done(outcome: outcome),
          ] else ...[
            const Text(
              'A spreadsheet saved as CSV. The first row should be the column '
              'headings.',
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.folder_open),
              label: Text(_file == null
                  ? 'Choose file'
                  : _file!.path.split('/').last),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            if (preview != null) ...[
              const SizedBox(height: 24),
              _Summary(preview: preview),
              const SizedBox(height: 20),
              Text('Which column is which',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Guessed from your headings — change anything that looks wrong.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              for (final field in ImportField.values)
                _MappingRow(
                  field: field,
                  headers: preview.headers,
                  selected: preview.mapping[field],
                  onChanged: (column) {
                    final next = Map<ImportField, int>.from(preview.mapping);
                    if (column == null) {
                      next.remove(field);
                    } else {
                      next.removeWhere((_, v) => v == column);
                      next[field] = column;
                    }
                    _reparse(mapping: next);
                  },
                ),
              if (preview.rows.any((r) => r.issues.isNotEmpty)) ...[
                const SizedBox(height: 20),
                _Issues(preview: preview),
              ],
              const SizedBox(height: 20),
              _BatchPicker(
                selected: _batchId,
                onChanged: (v) => setState(() => _batchId = v),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _busy ||
                        _batchId == null ||
                        preview.importable.isEmpty
                    ? null
                    : _import,
                icon: const Icon(Icons.download_done),
                label: Text('Import ${preview.importable.length} student(s)'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.preview});
  final ImportPreview preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${preview.rows.length} rows found',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('${preview.importable.length} can be imported'),
            if (preview.blockedCount > 0)
              Text('${preview.blockedCount} cannot — see below'),
            if (preview.warningCount > 0)
              Text('${preview.warningCount} worth a look'),
          ],
        ),
      ),
    );
  }
}

class _MappingRow extends StatelessWidget {
  const _MappingRow({
    required this.field,
    required this.headers,
    required this.selected,
    required this.onChanged,
  });

  final ImportField field;
  final List<String> headers;
  final int? selected;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              field.label + (field.required ? ' *' : ''),
              style: TextStyle(
                fontWeight: field.required ? FontWeight.bold : null,
              ),
            ),
          ),
          Expanded(
            flex: 5,
            child: DropdownButtonFormField<int?>(
              initialValue: selected,
              isDense: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('— not used —')),
                for (var i = 0; i < headers.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      headers[i].isEmpty ? 'Column ${i + 1}' : headers[i],
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _Issues extends StatelessWidget {
  const _Issues({required this.preview});
  final ImportPreview preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final flagged =
        preview.rows.where((r) => r.issues.isNotEmpty).toList(growable: false);

    return ExpansionTile(
      title: Text('${flagged.length} rows need attention'),
      subtitle: const Text('Rows that cannot import are listed first'),
      children: [
        for (final row in flagged.take(50))
          ListTile(
            dense: true,
            leading: Icon(
              row.blocked ? Icons.block : Icons.warning_amber,
              color: row.blocked
                  ? theme.colorScheme.error
                  : theme.colorScheme.tertiary,
              size: 20,
            ),
            title: Text(
              'Line ${row.lineNumber}'
              '${row.name.isEmpty ? '' : ' — ${row.name}'}',
            ),
            subtitle: Text(row.issues.map((i) => i.message).join('\n')),
          ),
        if (flagged.length > 50)
          ListTile(
            dense: true,
            title: Text('…and ${flagged.length - 50} more'),
          ),
      ],
    );
  }
}

class _BatchPicker extends ConsumerWidget {
  const _BatchPicker({required this.selected, required this.onChanged});

  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(activeSessionProvider).value;
    if (session == null) return const SizedBox.shrink();

    return StreamBuilder<List<StudentBatch>>(
      stream: ref.watch(masterDataProvider).watchBatches(session.id),
      builder: (context, snapshot) {
        final batches = snapshot.data ?? const <StudentBatch>[];
        if (batches.isEmpty) {
          return const Card(
            child: ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('No batches yet'),
              subtitle: Text(
                'Create a batch first — everyone imported joins one. You can '
                'move students between batches afterwards.',
              ),
            ),
          );
        }
        return DropdownButtonFormField<String>(
          initialValue: selected,
          items: [
            for (final b in batches)
              DropdownMenuItem(value: b.id, child: Text(b.name)),
          ],
          onChanged: onChanged,
          decoration: const InputDecoration(
            labelText: 'Admit everyone into',
            border: OutlineInputBorder(),
          ),
        );
      },
    );
  }
}

class _Done extends StatelessWidget {
  const _Done({required this.outcome});
  final ImportOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        const SizedBox(height: 30),
        Icon(Icons.check_circle_outline,
            size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text('${outcome.imported} students imported',
            style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        if (outcome.firstCode.isNotEmpty)
          Text('IDs ${outcome.firstCode} to ${outcome.lastCode}'),
        if (outcome.skipped > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('${outcome.skipped} rows were skipped'),
          ),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
