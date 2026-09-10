import 'package:drift/drift.dart'
    show BooleanExpressionOperators, OrderingTerm, Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../staff/staff_screen.dart';

/// What the builder still needs before it can produce a timetable.
class SetupStep {
  const SetupStep({
    required this.title,
    required this.question,
    required this.have,
    required this.ready,
    required this.fix,
  });

  final String title;

  /// Phrased as the question the owner is actually being asked.
  final String question;
  final String have;
  final bool ready;
  final String fix;
}

/// Walks the owner through what the routine builder needs.
///
/// A timetable cannot be produced from nothing, and the old screen simply
/// produced an empty grid and left the owner to work out why. This asks for
/// each thing in turn — how many teachers, how many periods in a day, how many
/// classes a week each subject needs — and shows what is already known, so the
/// answer to "why is my routine empty" is on the screen rather than inferred.
class RoutineSetupScreen extends ConsumerStatefulWidget {
  const RoutineSetupScreen({required this.onReady, super.key});

  final VoidCallback onReady;

  @override
  ConsumerState<RoutineSetupScreen> createState() => _RoutineSetupScreenState();
}

class _RoutineSetupScreenState extends ConsumerState<RoutineSetupScreen> {
  int _reloads = 0;
  void _refresh() => setState(() => _reloads++);

  @override
  Widget build(BuildContext context) {
    const section = Section.routine;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: const SectionAppBar(
        section: section,
        title: 'Before we build it',
      ),
      body: FutureBuilder<List<SetupStep>>(
        key: ValueKey(_reloads),
        future: _gather(),
        builder: (context, snapshot) {
          final steps = snapshot.data;
          if (steps == null) {
            return const Center(child: CircularProgressIndicator());
          }

          final done = steps.where((s) => s.ready).length;
          final ready = done == steps.length;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Card(
                elevation: 0,
                color: section.tint(context),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$done of ${steps.length} answered',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: done / steps.length),
                      const SizedBox(height: 10),
                      Text(
                        ready
                            ? 'That is everything. The builder will fill in what '
                                'it can and leave anything it cannot for you.'
                            : 'Answer these and the app can build most of the '
                                'timetable for you.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              for (var i = 0; i < steps.length; i++) ...[
                _StepCard(
                  index: i + 1,
                  step: steps[i],
                  onFix: () => _fix(i),
                ),
                const SizedBox(height: 12),
              ],

              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: ready ? widget.onReady : null,
                style: FilledButton.styleFrom(
                  backgroundColor: section.colour,
                  minimumSize: const Size.fromHeight(50),
                ),
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Build the routine'),
              ),
              if (!ready)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    'You can still open the grid and place classes by hand.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (!ready)
                TextButton(
                  onPressed: widget.onReady,
                  child: const Text('Open the grid anyway'),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<List<SetupStep>> _gather() async {
    final db = ref.read(databaseProvider);
    final session = await ref.read(activeSessionProvider.future);

    final classes = await (db.select(db.classes)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    final batches = session == null
        ? <StudentBatch>[]
        : await (db.select(db.batches)
              ..where((t) =>
                  t.sessionId.equals(session.id) & t.deletedAt.isNull()))
            .get();
    final teachers = await (db.select(db.staff)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.isActive.equals(true) &
              t.isTeacher.equals(true)))
        .get();
    final rooms = await (db.select(db.rooms)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    final slots = await (db.select(db.timeSlots)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    final requirements = await (db.select(db.subjectRequirements)
          ..where((t) => t.deletedAt.isNull()))
        .get();

    final withTeacher = requirements.where((r) => r.staffId != null).length;

    return [
      SetupStep(
        title: 'Classes and batches',
        question: 'How many classes do you run, and which batches are in them?',
        have: '${classes.length} class(es), ${batches.length} batch(es)',
        ready: batches.isNotEmpty,
        fix: 'Add a batch',
      ),
      SetupStep(
        title: 'Teachers',
        question: 'How many teachers do you have?',
        have: '${teachers.length} teacher(s)',
        ready: teachers.isNotEmpty,
        fix: 'Add a teacher',
      ),
      SetupStep(
        title: 'Rooms',
        question: 'How many rooms can classes run in?',
        have: '${rooms.length} room(s)',
        ready: rooms.isNotEmpty,
        fix: 'Add a room',
      ),
      SetupStep(
        title: 'Class times',
        question: 'How many periods are there in a day, and when?',
        have: '${slots.length} period(s) a day',
        ready: slots.isNotEmpty,
        fix: 'Add a period',
      ),
      SetupStep(
        title: 'Subjects each week',
        question:
            'How many times a week does each subject meet, and who teaches it?',
        have: requirements.isEmpty
            ? 'not set'
            : '${requirements.length} subject slot(s), '
                '$withTeacher with a teacher',
        ready: requirements.isNotEmpty && withTeacher > 0,
        fix: 'Set subjects and teachers',
      ),
    ];
  }

  Future<void> _fix(int index) async {
    switch (index) {
      case 0:
        await _addBatch();
      case 1:
        await _addTeacher();
      case 2:
        await _addRoom();
      case 3:
        await _addSlot();
      case 4:
        await _editRequirements();
    }
    _refresh();
  }

  Future<void> _addTeacher() async {
    final result = await showStaffSheet(context: context, isTeacher: true);
    if (result == null) return;
    await ref.read(staffRepositoryProvider).add(
          name: result.name,
          isTeacher: true,
          phone: result.phone,
          role: result.role,
          payModel: result.payModel,
          monthlySalary: result.monthlySalary,
          perClassRate: result.perClassRate,
          hourlyRate: result.hourlyRate,
        );
  }

  Future<void> _addRoom() async {
    final name = TextEditingController();
    final capacity = TextEditingController(text: '30');
    final ok = await _sheet(
      title: 'Add a room',
      fields: [(name, 'Room name', null), (capacity, 'Seats', TextInputType.number)],
    );
    if (ok != true || name.text.trim().isEmpty) return;
    await ref
        .read(masterDataProvider)
        .addRoom(name.text.trim(), int.tryParse(capacity.text) ?? 30);
  }

  Future<void> _addSlot() async {
    final start = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 16, minute: 0),
      helpText: 'Period starts',
    );
    if (start == null || !mounted) return;
    final end = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: start.hour + 1, minute: start.minute),
      helpText: 'Period ends',
    );
    if (end == null) return;

    final from = start.hour * 60 + start.minute;
    final to = end.hour * 60 + end.minute;
    if (to <= from) return;

    await ref.read(masterDataProvider).addTimeSlot(
          label: '${_hhmm(from)} – ${_hhmm(to)}',
          startMinute: from,
          endMinute: to,
        );
  }

  Future<void> _addBatch() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Add batches from Students → Batches, then come back.'),
      ),
    );
  }

  Future<void> _editRequirements() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SubjectPlanScreen()),
    );
  }

  Future<bool?> _sheet({
    required String title,
    required List<(TextEditingController, String, TextInputType?)> fields,
  }) =>
      showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        builder: (context) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              for (final (controller, label, keyboard) in fields) ...[
                TextField(
                  controller: controller,
                  keyboardType: keyboard,
                  decoration: InputDecoration(
                    labelText: label,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Add'),
                ),
              ),
            ],
          ),
        ),
      );

  static String _hhmm(int minutes) {
    final h24 = minutes ~/ 60;
    final m = minutes % 60;
    final period = h24 >= 12 ? 'PM' : 'AM';
    final h = h24 % 12 == 0 ? 12 : h24 % 12;
    return '$h:${m.toString().padLeft(2, '0')} $period';
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.index,
    required this.step,
    required this.onFix,
  });

  final int index;
  final SetupStep step;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    const section = Section.routine;
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: step.ready
              ? section.colour.withValues(alpha: 0.4)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 15,
              backgroundColor: step.ready
                  ? section.colour
                  : theme.colorScheme.surfaceContainerHighest,
              foregroundColor:
                  step.ready ? Colors.white : theme.colorScheme.outline,
              child: step.ready
                  ? const Icon(Icons.check, size: 17)
                  : Text('$index'),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(step.question, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(step.have,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: step.ready
                            ? section.onTint(context)
                            : theme.colorScheme.outline,
                      )),
                  const SizedBox(height: 6),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: onFix,
                    child: Text(step.ready ? 'Change' : step.fix),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How often each subject meets in each batch, and who takes it.
///
/// Batch-wise on purpose: two batches of the same class rarely study the same
/// list. One takes Higher Maths, the other does not; one has an extra ICT
/// period. So the plan belongs to the batch, subjects can be added to a batch
/// by hand, and removing one from a batch does not touch the others.
class SubjectPlanScreen extends ConsumerStatefulWidget {
  const SubjectPlanScreen({super.key});

  @override
  ConsumerState<SubjectPlanScreen> createState() => _SubjectPlanScreenState();
}

class _SubjectPlanScreenState extends ConsumerState<SubjectPlanScreen> {
  int _reloads = 0;
  void _refresh() => setState(() => _reloads++);

  @override
  Widget build(BuildContext context) {
    const section = Section.routine;
    final session = ref.watch(activeSessionProvider).value;

    return Scaffold(
      appBar: const SectionAppBar(
        section: section,
        title: 'Subjects each week',
      ),
      body: session == null
          ? const Center(child: CircularProgressIndicator())
          : FutureBuilder<List<_BatchPlan>>(
              key: ValueKey(_reloads),
              future: _load(session.id),
              builder: (context, snapshot) {
                final plans = snapshot.data;
                if (plans == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (plans.isEmpty) {
                  return const EmptyState(
                    section: section,
                    title: 'No batches yet',
                    body: 'A weekly plan belongs to a batch, so create one '
                        'first from Students → Batches.',
                  );
                }

                return ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Each batch has its own list — two batches of the same '
                        'class need not study the same subjects. Set how many '
                        'periods a week each one meets, and who teaches it.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    for (final plan in plans)
                      ExpansionTile(
                        initiallyExpanded: plans.length == 1,
                        collapsedBackgroundColor: section.tint(context),
                        backgroundColor: section.tint(context),
                        title: Text(plan.batch.name),
                        subtitle: Text(
                          '${plan.className} · '
                          '${plan.rows.fold<int>(0, (n, r) => n + r.periods)} '
                          'period(s) a week',
                        ),
                        children: [
                          for (final row in plan.rows)
                            ListTile(
                              tileColor: Theme.of(context).colorScheme.surface,
                              title: Text(row.subject.name),
                              subtitle: Text(
                                row.teacher?.name ?? 'No teacher chosen',
                                style: TextStyle(
                                  color: row.teacher == null
                                      ? Theme.of(context).colorScheme.outline
                                      : null,
                                ),
                              ),
                              onTap: () => _rowMenu(plan.batch, row),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon:
                                        const Icon(Icons.remove_circle_outline),
                                    onPressed: row.periods == 0
                                        ? null
                                        : () => _setPeriods(
                                            plan.batch, row, row.periods - 1),
                                  ),
                                  SizedBox(
                                    width: 22,
                                    child: Text('${row.periods}',
                                        textAlign: TextAlign.center),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.add_circle_outline),
                                    onPressed: () => _setPeriods(
                                        plan.batch, row, row.periods + 1),
                                  ),
                                ],
                              ),
                            ),
                          ListTile(
                            tileColor: Theme.of(context).colorScheme.surface,
                            leading: Icon(Icons.add, color: section.colour),
                            title: Text(
                              'Add a subject to ${plan.batch.name}',
                              style: TextStyle(color: section.colour),
                            ),
                            onTap: () => _addSubject(plan),
                          ),
                        ],
                      ),
                  ],
                );
              },
            ),
    );
  }

  Future<List<_BatchPlan>> _load(String sessionId) async {
    final db = ref.read(databaseProvider);

    // Seeds a row per batch per class subject, so a new centre sees a sensible
    // starting list instead of an empty one it has to type from scratch.
    await ref.read(routineProvider).seedRequirements(sessionId);

    final batches = await (db.select(db.batches)
          ..where((t) => t.sessionId.equals(sessionId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();
    final classRows = await (db.select(db.classes)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    final classNames = {for (final c in classRows) c.id: c.name};
    final teachers = await (db.select(db.staff)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.isActive.equals(true) &
              t.isTeacher.equals(true)))
        .get();
    final subjects = await (db.select(db.subjects)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
    final subjectsById = {for (final s in subjects) s.id: s};
    final requirements = await (db.select(db.subjectRequirements)
          ..where((t) => t.deletedAt.isNull()))
        .get();

    return [
      for (final batch in batches)
        _BatchPlan(
          batch: batch,
          className: classNames[batch.classId] ?? 'Class',
          all: subjects,
          rows: [
            // Driven by the batch's own requirements, not by its class's
            // subject list — that is what makes the list batch-specific.
            for (final r in requirements.where((r) => r.batchId == batch.id))
              if (subjectsById[r.subjectId] != null)
                _PlanRow(
                  subject: subjectsById[r.subjectId]!,
                  periods: r.periodsPerWeek,
                  teacher:
                      teachers.where((t) => t.id == r.staffId).firstOrNull,
                  requirementId: r.id,
                ),
          ]..sort((a, b) => a.subject.name.compareTo(b.subject.name)),
        ),
    ];
  }

  Future<void> _setPeriods(
      StudentBatch batch, _PlanRow row, int periods) async {
    final db = ref.read(databaseProvider);
    await (db.update(db.subjectRequirements)
          ..where((t) => t.id.equals(row.requirementId)))
        .write(
      SubjectRequirementsCompanion(
        periodsPerWeek: Value(periods),
        updatedAt: Value(DateTime.now()),
      ),
    );
    _refresh();
  }

  Future<void> _rowMenu(StudentBatch batch, _PlanRow row) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(row.subject.name,
                  style: Theme.of(context).textTheme.titleMedium),
              subtitle: Text('in ${batch.name}'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Who teaches this'),
              onTap: () => Navigator.pop(context, 'teacher'),
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: Text('Remove from ${batch.name}'),
              subtitle: const Text('Other batches keep it'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          ],
        ),
      ),
    );

    if (choice == 'teacher') {
      await _chooseTeacher(row);
    } else if (choice == 'remove') {
      await _removeSubject(row);
    }
  }

  Future<void> _removeSubject(_PlanRow row) async {
    final db = ref.read(databaseProvider);
    await (db.update(db.subjectRequirements)
          ..where((t) => t.id.equals(row.requirementId)))
        .write(
      SubjectRequirementsCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
    _refresh();
  }

  Future<void> _chooseTeacher(_PlanRow row) async {
    final teachers =
        await ref.read(staffRepositoryProvider).watchTeachers().first;
    if (!mounted) return;

    final chosen = await showDialog<StaffMember>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Who teaches ${row.subject.name}?'),
        children: [
          for (final t in teachers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, t),
              child: Text(t.name),
            ),
          if (teachers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('No teachers added yet.'),
            ),
        ],
      ),
    );
    if (chosen == null) return;

    final db = ref.read(databaseProvider);
    await (db.update(db.subjectRequirements)
          ..where((t) => t.id.equals(row.requirementId)))
        .write(
      SubjectRequirementsCompanion(
        staffId: Value(chosen.id),
        updatedAt: Value(DateTime.now()),
      ),
    );
    _refresh();
  }

  /// Adds a subject to one batch — either one that already exists anywhere in
  /// the centre, or a brand new one typed in on the spot.
  Future<void> _addSubject(_BatchPlan plan) async {
    final taken = {for (final r in plan.rows) r.subject.id};
    final available =
        plan.all.where((s) => !taken.contains(s.id)).toList();
    final name = TextEditingController();

    final chosen = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          builder: (context, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.all(20),
            children: [
              Text('Add a subject to ${plan.batch.name}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'New subject',
                        hintText: 'Type a name',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (value) => value.trim().isEmpty
                          ? null
                          : Navigator.pop(context, value.trim()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Section.routine.colour,
                    ),
                    onPressed: () => name.text.trim().isEmpty
                        ? null
                        : Navigator.pop(context, name.text.trim()),
                    child: const Text('Add'),
                  ),
                ],
              ),
              if (available.isNotEmpty) ...[
                const SectionHeading('Or one you already have',
                    section: Section.routine),
                for (final subject in available)
                  ListTile(
                    title: Text(subject.name),
                    onTap: () => Navigator.pop(context, subject),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
    if (chosen == null) return;

    final db = ref.read(databaseProvider);
    final deviceId = ref.read(deviceIdProvider);

    var subjectId = chosen is Subject ? chosen.id : null;
    if (subjectId == null) {
      // A typed name belongs to the batch's own class, so it shows up for the
      // rest of that class too — which is what an owner adding "Higher Maths"
      // to Class 9 actually means.
      final created = await ref.read(masterDataProvider).addSubject(
            classId: plan.batch.classId,
            name: chosen as String,
          );
      subjectId = created.id;
    }

    // A subject removed earlier leaves a soft-deleted row behind; revive it
    // rather than inserting a second one for the same pair.
    final previous = await (db.select(db.subjectRequirements)
          ..where((t) =>
              t.batchId.equals(plan.batch.id) &
              t.subjectId.equals(subjectId!)))
        .getSingleOrNull();

    if (previous == null) {
      await db.into(db.subjectRequirements).insert(
            SubjectRequirementsCompanion.insert(
              batchId: plan.batch.id,
              subjectId: subjectId,
              deviceId: deviceId,
              periodsPerWeek: const Value(2),
            ),
          );
    } else {
      await (db.update(db.subjectRequirements)
            ..where((t) => t.id.equals(previous.id)))
          .write(
        SubjectRequirementsCompanion(
          deletedAt: const Value(null),
          periodsPerWeek: Value(previous.periodsPerWeek == 0
              ? 2
              : previous.periodsPerWeek),
          updatedAt: Value(DateTime.now()),
        ),
      );
    }
    _refresh();
  }
}

class _BatchPlan {
  const _BatchPlan({
    required this.batch,
    required this.className,
    required this.rows,
    required this.all,
  });

  final StudentBatch batch;
  final String className;
  final List<_PlanRow> rows;

  /// Every subject in the centre, so one batch can borrow another's.
  final List<Subject> all;
}

class _PlanRow {
  const _PlanRow({
    required this.subject,
    required this.periods,
    required this.teacher,
    required this.requirementId,
  });

  final Subject subject;
  final int periods;
  final StaffMember? teacher;
  final String requirementId;
}
