import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';

/// Batches for the active session: the unit students are enrolled into and fees
/// are priced against.
class BatchesScreen extends ConsumerWidget {
  const BatchesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(masterDataProvider);
    final session = ref.watch(activeSessionProvider).value;

    return Scaffold(
      appBar: const SectionAppBar(section: Section.students, title: 'Batches'),
      floatingActionButton: session == null
          ? null
          : FloatingActionButton.extended(
            backgroundColor: Section.students.colour,
            foregroundColor: Colors.white,
              onPressed: () => _openEditor(context, ref, session.id),
              icon: const Icon(Icons.add),
              label: const Text('New batch'),
            ),
      body: session == null
          ? const Center(child: CircularProgressIndicator())
          : StreamBuilder<List<StudentBatch>>(
              stream: repo.watchBatches(session.id),
              builder: (context, snapshot) {
                final batches = snapshot.data;
                if (batches == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (batches.isEmpty) {
                  return _Empty(
                    onCreate: () => _openEditor(context, ref, session.id),
                  );
                }
                return ListView.separated(
                  itemCount: batches.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final batch = batches[i];
                    return ListTile(
                      title: Text(batch.name),
                      subtitle: Text(
                        [
                          if (batch.groupName.isNotEmpty) batch.groupName,
                          'Capacity ${batch.capacity}',
                          if (batch.monthlyFee > 0) '৳${batch.monthlyFee}/month',
                        ].join(' · '),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.archive_outlined),
                        tooltip: 'Archive',
                        onPressed: () => _confirmArchive(context, ref, batch),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  Future<void> _confirmArchive(
    BuildContext context,
    WidgetRef ref,
    StudentBatch batch,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Archive ${batch.name}?'),
        content: const Text(
          'It disappears from lists but keeps its history, so past fees and '
          'attendance stay answerable. Nothing is deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (ok ?? false) await ref.read(masterDataProvider).archiveBatch(batch);
  }

  Future<void> _openEditor(
    BuildContext context,
    WidgetRef ref,
    String sessionId,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BatchEditor(sessionId: sessionId),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.groups_outlined, size: 44),
              const SizedBox(height: 14),
              Text(
                'No batches yet',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              const Text(
                'A batch is a group taught together — "Class 9 Science A". '
                'Students are admitted into batches, and fees are priced per '
                'batch.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              FilledButton(onPressed: onCreate, child: const Text('Add the first batch')),
            ],
          ),
        ),
      );
}

class _BatchEditor extends ConsumerStatefulWidget {
  const _BatchEditor({required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<_BatchEditor> createState() => _BatchEditorState();
}

class _BatchEditorState extends ConsumerState<_BatchEditor> {
  final _name = TextEditingController();
  final _group = TextEditingController();
  final _capacity = TextEditingController(text: '30');
  final _fee = TextEditingController(text: '0');
  String? _classId;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _group.dispose();
    _capacity.dispose();
    _fee.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(masterDataProvider).addBatch(
            sessionId: widget.sessionId,
            classId: _classId!,
            name: _name.text.trim(),
            groupName: _group.text.trim(),
            capacity: int.tryParse(_capacity.text) ?? 30,
            monthlyFee: int.tryParse(_fee.text) ?? 0,
          );
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(masterDataProvider);
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: StreamBuilder<List<SchoolClass>>(
        stream: repo.watchClasses(),
        builder: (context, snapshot) {
          final classes = snapshot.data ?? const <SchoolClass>[];
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('New batch', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _classId,
                items: [
                  for (final c in classes)
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => _classId = v),
                decoration: const InputDecoration(
                  labelText: 'Class',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Batch name',
                  hintText: 'Science A',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _capacity,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Capacity',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _fee,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Monthly fee',
                        prefixText: '৳ ',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy || _classId == null || _name.text.trim().isEmpty
                      ? null
                      : _save,
                  child: const Text('Create batch'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
