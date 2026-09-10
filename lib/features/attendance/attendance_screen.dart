import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';

/// Taking the register for one batch.
///
/// Opens with everyone present. A teacher with forty students in front of them
/// has seconds, not minutes, and the overwhelmingly common case is that almost
/// everyone turned up — so the work is marking the exceptions, not marking
/// everybody.
class AttendanceScreen extends ConsumerStatefulWidget {
  const AttendanceScreen({super.key});

  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends ConsumerState<AttendanceScreen> {
  StudentBatch? _batch;
  ClassSession? _session;
  List<Student> _roster = const [];
  final _states = <String, AttendanceState>{};
  bool _busy = false;

  Future<void> _open(StudentBatch batch) async {
    setState(() => _busy = true);
    final service = ref.read(attendanceServiceProvider);
    final session = await service.openSession(batchId: batch.id);
    final roster =
        await ref.read(studentsProvider).watchBatchRoster(batch.id).first;
    final existing = await service.statesFor(session.id);

    if (!mounted) return;
    setState(() {
      _batch = batch;
      _session = session;
      _roster = roster;
      _states
        ..clear()
        ..addEntries(
          roster.map(
            (s) => MapEntry(s.id, existing[s.id] ?? AttendanceState.present),
          ),
        );
      _busy = false;
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(attendanceServiceProvider).saveSession(
            sessionId: _session!.id,
            states: Map.of(_states),
          );
      if (!mounted) return;
      final absent =
          _states.values.where((s) => s == AttendanceState.absent).length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved — $absent absent of ${_states.length}')),
      );
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_batch == null) return _BatchChooser(onChosen: _open);

    final theme = Theme.of(context);
    final absent =
        _states.values.where((s) => s == AttendanceState.absent).length;

    return Scaffold(
      appBar: SectionAppBar(
        section: Section.attendance,
        title: _batch!.name,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${_states.length - absent} present · $absent absent',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Section.attendance.colour,
        foregroundColor: Colors.white,
        onPressed: _busy ? null : _save,
        icon: const Icon(Icons.check),
        label: const Text('Save'),
      ),
      body: _roster.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Nobody is enrolled in this batch yet.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              itemCount: _roster.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final student = _roster[i];
                final state = _states[student.id] ?? AttendanceState.present;
                return ListTile(
                  dense: true,
                  leading: Text('${i + 1}',
                      style: theme.textTheme.bodySmall),
                  title: Text(student.name),
                  subtitle: Text(student.code),
                  trailing: _StateToggle(
                    state: state,
                    onChanged: (next) =>
                        setState(() => _states[student.id] = next),
                  ),
                );
              },
            ),
    );
  }
}

/// One tap cycles present → absent → late → excused → present.
///
/// A cycle rather than four buttons: the row stays narrow enough for a name to
/// fit, and the two states that matter are one tap apart.
class _StateToggle extends StatelessWidget {
  const _StateToggle({required this.state, required this.onChanged});

  final AttendanceState state;
  final ValueChanged<AttendanceState> onChanged;

  @override
  Widget build(BuildContext context) {
    final (label, colour) = switch (state) {
      AttendanceState.present => ('Present', Colors.green),
      AttendanceState.absent => ('Absent', Colors.red),
      AttendanceState.late => ('Late', Colors.orange),
      AttendanceState.excused => ('Excused', Colors.blueGrey),
    };

    return SizedBox(
      width: 104,
      child: OutlinedButton(
        onPressed: () {
          const order = AttendanceState.values;
          onChanged(order[(order.indexOf(state) + 1) % order.length]);
        },
        style: OutlinedButton.styleFrom(
          foregroundColor: colour,
          side: BorderSide(color: colour),
          padding: const EdgeInsets.symmetric(horizontal: 4),
        ),
        child: Text(label),
      ),
    );
  }
}

class _BatchChooser extends ConsumerWidget {
  const _BatchChooser({required this.onChosen});
  final ValueChanged<StudentBatch> onChosen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(activeSessionProvider).value;
    return Scaffold(
      appBar: const SectionAppBar(section: Section.attendance, title: 'Attendance'),
      body: session == null
          ? const Center(child: CircularProgressIndicator())
          : StreamBuilder<List<StudentBatch>>(
              stream: ref.watch(masterDataProvider).watchBatches(session.id),
              builder: (context, snapshot) {
                final batches = snapshot.data ?? const <StudentBatch>[];
                if (batches.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Create a batch first — attendance is taken per batch.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                return ListView(
                  children: [
                    for (final b in batches)
                      ListTile(
                        leading: const Icon(Icons.groups_outlined),
                        title: Text(b.name),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => onChosen(b),
                      ),
                  ],
                );
              },
            ),
    );
  }
}
