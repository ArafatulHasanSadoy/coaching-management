import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/routine/routine_engine.dart';
import '../../data/routine/routine_model.dart';
import '../../data/routine/routine_solver.dart';
import 'routine_document.dart';
import 'routine_setup_screen.dart';

const _section = Section.routine;

/// The timetable, one class at a time.
///
/// A coaching centre reads its routine by class — "what does Class 9 do on
/// Sunday" — not by batch, even though batches are what actually get
/// scheduled. So the grid is drawn per class with every batch of that class
/// merged into the same sheet, each cell tagged with the batch it belongs to.
///
/// Anything the solver could not place is simply left blank for the owner to
/// fill in by hand; a half-built routine you can finish yourself is far more
/// use than a failure message.
class RoutineScreen extends ConsumerStatefulWidget {
  const RoutineScreen({super.key});

  @override
  ConsumerState<RoutineScreen> createState() => _RoutineScreenState();
}

class _RoutineScreenState extends ConsumerState<RoutineScreen> {
  RoutineVersion? _version;
  RoutineProblem? _problem;
  List<Placement> _placements = [];
  SolveResult? _lastSolve;
  bool _busy = false;
  String? _classFilter;
  String? _batchFilter;

  /// A routine is *built* one batch at a time — that is the unit a period
  /// actually belongs to, and the unit a week gets copied between. Class-wise
  /// merges a class's batches onto one sheet afterwards, which is how a notice
  /// board reads. So building is the default and class-wise is the view.
  bool _byBatch = true;

  Future<void> _load(RoutineVersion version) async {
    setState(() => _busy = true);
    final repo = ref.read(routineProvider);
    final session = await ref.read(activeSessionProvider.future);
    await repo.seedRequirements(session!.id);

    final problem =
        await repo.loadProblem(sessionId: session.id, versionId: version.id);
    final entries = await repo.watchEntries(version.id).first;

    if (!mounted) return;
    setState(() {
      _version = version;
      _problem = problem;
      _placements = [
        for (final e in entries)
          Placement(
            batchId: e.batchId,
            subjectId: e.subjectId,
            staffId: e.staffId,
            roomId: e.roomId,
            day: e.dayOfWeek,
            slotId: e.slotId,
            isPinned: e.isPinned,
          ),
      ];
      _classFilter ??= problem.batches.firstOrNull?.classId;
      _batchFilter ??= problem.batches.firstOrNull?.id;
      _busy = false;
    });
  }

  /// What the grid is currently showing: one batch, or a class's batches
  /// merged onto a single sheet.
  List<BatchRef> get _batchesInView {
    final problem = _problem!;
    if (_byBatch) {
      return problem.batches.where((b) => b.id == _batchFilter).toList();
    }
    if (_classFilter == null) return problem.batches;
    return problem.batches.where((b) => b.classId == _classFilter).toList();
  }

  List<({String id, String name})> get _classes {
    final seen = <String, String>{};
    for (final batch in _problem!.batches) {
      seen.putIfAbsent(batch.classId, () => batch.className);
    }
    return [for (final e in seen.entries) (id: e.key, name: e.value)];
  }

  Future<void> _generate(SolveMode mode) async {
    final problem = _problem;
    if (problem == null) return;
    setState(() => _busy = true);

    // Off the UI thread: a centre-sized problem is a few hundred thousand
    // placement checks and would visibly freeze the phone.
    final result = await compute(
      solveRoutine,
      SolveRequest(problem: problem, mode: mode),
    );

    await ref.read(routineProvider).savePlacements(
          versionId: _version!.id,
          placements: result.placements,
        );

    if (!mounted) return;
    setState(() {
      _placements = result.placements;
      _lastSolve = result;
      _busy = false;
    });

    if (!result.isComplete && mounted) {
      await _showUnplaced(result);
    }
  }

  Future<void> _showUnplaced(SolveResult result) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (context, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '${result.completeness.toStringAsFixed(0)}% scheduled',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                '${result.unplaced.length} thing(s) could not be placed, so '
                'those cells are blank. Tap any blank cell to put a class '
                'there yourself — the app will only offer what actually fits.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 18),
              for (final unplaced in result.unplaced)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_problem!.nameOfBatch(unplaced.requirement.batchId)}'
                          ' — ${_problem!.nameOfSubject(unplaced.requirement.subjectId)}',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          'Wanted ${unplaced.wanted}, placed ${unplaced.placed}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Text(unplaced.reason),
                        const SizedBox(height: 10),
                        const Text('What would fix it:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        for (final fix in unplaced.suggestions)
                          Text('•  $fix'),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );

  Future<void> _openCell(int day, SlotRef slot) async {
    final problem = _problem!;
    final batchIds = {for (final b in _batchesInView) b.id};

    final here = _placements
        .where((p) =>
            p.day == day && p.slotId == slot.id && batchIds.contains(p.batchId))
        .toList();

    final options = RoutineEngine.candidatesFor(
      problem: problem,
      day: day,
      slotId: slot.id,
      existing: _placements,
    ).where((c) => batchIds.contains(c.batchId)).toList();

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(16),
          children: [
            Text('${bengaliWeek[day]} · ${slot.label}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              _classFilter == null
                  ? 'All classes'
                  : _classes
                      .where((c) => c.id == _classFilter)
                      .map((c) => c.name)
                      .firstOrNull ??
                      '',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (here.isNotEmpty) ...[
              const SizedBox(height: 16),
              const SectionHeading('Already here', section: _section),
              for (final p in here)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(problem.nameOfSubject(p.subjectId)),
                  subtitle: Text([
                    problem.nameOfBatch(p.batchId),
                    if (p.staffId != null) problem.nameOfStaff(p.staffId!),
                    if (p.roomId != null) problem.nameOfRoom(p.roomId!),
                  ].join(' · ')),
                  trailing: IconButton(
                    tooltip: 'Clear this',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      Navigator.pop(context);
                      _remove(p);
                    },
                  ),
                ),
            ],
            const SizedBox(height: 16),
            SectionHeading(
              here.isEmpty ? 'What can go here' : 'Add another batch',
              section: _section,
            ),
            if (options.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'Nothing else fits this slot without a clash — every '
                  'remaining subject needs a teacher, room or batch that is '
                  'already busy at this time.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            for (final option in options)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: _section.tint(context),
                  foregroundColor: _section.onTint(context),
                  child: Text('${option.remaining}'),
                ),
                title: Text(problem.nameOfSubject(option.subjectId)),
                subtitle: Text([
                  problem.nameOfBatch(option.batchId),
                  if (option.staffId != null)
                    problem.nameOfStaff(option.staffId!),
                  if (option.roomId != null) problem.nameOfRoom(option.roomId!),
                ].join(' · ')),
                onTap: () {
                  Navigator.pop(context);
                  _place(option, day, slot);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _place(Candidate chosen, int day, SlotRef slot) async {
    final placement = Placement(
      batchId: chosen.batchId,
      subjectId: chosen.subjectId,
      staffId: chosen.staffId,
      roomId: chosen.roomId,
      day: day,
      slotId: slot.id,
      isPinned: true,
    );
    await ref
        .read(routineProvider)
        .addEntry(versionId: _version!.id, placement: placement);
    if (!mounted) return;
    setState(() => _placements = [..._placements, placement]);
  }

  Future<void> _remove(Placement placement) async {
    await ref.read(routineProvider).removeAt(
          versionId: _version!.id,
          batchId: placement.batchId,
          day: placement.day,
          slotId: placement.slotId,
        );
    if (!mounted) return;
    setState(() {
      _placements = _placements
          .where((p) => !(p.batchId == placement.batchId &&
              p.day == placement.day &&
              p.slotId == placement.slotId))
          .toList();
    });
  }

  /// Copy one batch's week onto another.
  Future<void> _copyInto(BatchRef target) async {
    final problem = _problem!;
    final sources =
        problem.batches.where((b) => b.id != target.id).toList();

    if (sources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('There is only one batch — nothing to copy from.'),
        ),
      );
      return;
    }

    final from = await showModalBottomSheet<BatchRef>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(20),
          children: [
            Text('Copy a week into ${target.name}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              "Whatever ${target.name} has now is replaced. Subjects are "
              'matched by name, and where ${target.name} has already named a '
              'teacher for a subject, that teacher is used instead of the one '
              'being copied from. Anything that would clash is left blank for '
              'you.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SectionHeading('Copy from', section: _section),
            for (final batch in sources)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: _section.tint(context),
                  foregroundColor: _section.onTint(context),
                  child: const Icon(Icons.copy_all_outlined, size: 18),
                ),
                title: Text(batch.name),
                subtitle: Text(
                  '${batch.className} · '
                  '${_placements.where((p) => p.batchId == batch.id).length} '
                  'period(s)',
                ),
                onTap: () => Navigator.pop(context, batch),
              ),
          ],
        ),
      ),
    );
    if (from == null || !mounted) return;

    setState(() => _busy = true);
    final outcome = await ref.read(routineProvider).copyBatch(
          versionId: _version!.id,
          problem: problem,
          fromBatchId: from.id,
          toBatchId: target.id,
        );
    await _load(_version!);
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          outcome.isClean
              ? 'Copied'
              : '${outcome.copied} period(s) copied',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final note in outcome.notes) ...[
              Text(note),
              const SizedBox(height: 10),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Future<void> _print() async {
    final engine = ref.read(documentEngineProvider);
    final html = RoutineDocument(engine: engine).build(
      problem: _problem!,
      placements: _placements,
      versionName: _version!.name,
      classId: _byBatch ? null : _classFilter,
      batchId: _byBatch ? _batchFilter : null,
    );
    await engine.printDocument(html, jobName: 'Routine ${_version!.name}');
  }

  @override
  Widget build(BuildContext context) {
    if (_version == null) return _VersionPicker(onOpen: _load);

    final problem = _problem!;
    final theme = Theme.of(context);
    final classes = _classes;
    final batches = _batchesInView;
    final batchIds = {for (final b in batches) b.id};
    final shown =
        _placements.where((p) => batchIds.contains(p.batchId)).toList();

    // How many periods this class still owes, so the blanks have a number
    // attached rather than looking like the app simply stopped.
    final owed = problem.requirements
        .where((r) => batchIds.contains(r.batchId))
        .fold<int>(0, (n, r) => n + r.periodsPerWeek) -
        shown.length;

    return Scaffold(
      appBar: SectionAppBar(
        section: _section,
        title: _version!.name,
        actions: [
          IconButton(
            tooltip: 'What the builder needs',
            icon: const Icon(Icons.checklist_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RoutineSetupScreen(
                  onReady: () => Navigator.of(context).pop(),
                ),
              ),
            ).then((_) => _load(_version!)),
          ),
          IconButton(
            tooltip: 'Print',
            icon: const Icon(Icons.print_outlined),
            onPressed: _placements.isEmpty ? null : _print,
          ),
          PopupMenuButton<SolveMode>(
            icon: const Icon(Icons.auto_awesome),
            tooltip: 'Fill it in for me',
            onSelected: _generate,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: SolveMode.fast,
                child: Text('Fill in — quick'),
              ),
              PopupMenuItem(
                value: SolveMode.balanced,
                child: Text('Fill in — best spread'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_lastSolve != null)
            Material(
              color: _lastSolve!.isComplete
                  ? _section.tint(context)
                  : theme.colorScheme.errorContainer,
              child: InkWell(
                onTap: _lastSolve!.isComplete
                    ? null
                    : () => _showUnplaced(_lastSolve!),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _lastSolve!.isComplete
                        ? 'Fully scheduled — no clashes.'
                        : '${_lastSolve!.completeness.toStringAsFixed(0)}% filled in · '
                            '${_lastSolve!.unplaced.length} left blank for you — tap to see why',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<bool>(
                    style: SegmentedButton.styleFrom(
                      selectedBackgroundColor: _section.tint(context),
                      selectedForegroundColor: _section.onTint(context),
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(
                        value: true,
                        label: Text('Build by batch'),
                        icon: Icon(Icons.groups_outlined, size: 17),
                      ),
                      ButtonSegment(
                        value: false,
                        label: Text('Whole class'),
                        icon: Icon(Icons.grid_view_outlined, size: 17),
                      ),
                    ],
                    selected: {_byBatch},
                    onSelectionChanged: (value) =>
                        setState(() => _byBatch = value.first),
                  ),
                ),
                if (_byBatch && batches.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Copy another batch\u2019s week into this one',
                    icon: const Icon(Icons.content_paste_go),
                    onPressed: () => _copyInto(batches.first),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(
            height: 54,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                if (_byBatch)
                  for (final batch in problem.batches)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 9),
                      child: ChoiceChip(
                        label: Text(batch.name),
                        selected: _batchFilter == batch.id,
                        selectedColor: _section.tint(context),
                        onSelected: (_) =>
                            setState(() => _batchFilter = batch.id),
                      ),
                    )
                else
                  for (final klass in classes)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 9),
                      child: ChoiceChip(
                        label: Text(klass.name),
                        selected: _classFilter == klass.id,
                        selectedColor: _section.tint(context),
                        onSelected: (_) =>
                            setState(() => _classFilter = klass.id),
                      ),
                    ),
              ],
            ),
          ),
          if (batches.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
              child: Row(
                children: [
                  Icon(Icons.groups_outlined,
                      size: 15, color: theme.colorScheme.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${batches.length} batches on one sheet: '
                      '${batches.map((b) => b.name).join(', ')}',
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (owed > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Row(
                children: [
                  Icon(Icons.edit_outlined,
                      size: 15, color: theme.colorScheme.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '$owed period(s) still to place — tap any blank cell.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: problem.slots.isEmpty
                ? EmptyState(
                    section: _section,
                    title: 'No class times yet',
                    body: 'A timetable needs to know when your periods run.',
                    action: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: _section.colour),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => RoutineSetupScreen(
                            onReady: () => Navigator.of(context).pop(),
                          ),
                        ),
                      ).then((_) => _load(_version!)),
                      child: const Text('Set it up'),
                    ),
                  )
                : _Grid(
                    problem: problem,
                    placements: shown,
                    showBatch: batches.length > 1,
                    onTap: _openCell,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Days across, periods down — the shape every printed routine already uses.
///
/// The period column is frozen: a timetable you have to scroll sideways is
/// useless if the times scroll away with it. That means row heights have to be
/// computed rather than left to `IntrinsicHeight`, because the frozen column
/// and the scrolling one are separate widgets and must line up exactly.
class _Grid extends StatelessWidget {
  const _Grid({
    required this.problem,
    required this.placements,
    required this.showBatch,
    required this.onTap,
  });

  final RoutineProblem problem;
  final List<Placement> placements;

  /// Only worth the extra line when more than one batch shares the sheet.
  final bool showBatch;
  final void Function(int day, SlotRef slot) onTap;

  static const _slotWidth = 78.0;
  static const _cellWidth = 118.0;
  static const _headerHeight = 38.0;
  static const _lineHeight = 17.0;
  static const _dividerHeight = 9.0;
  static const _cellPadding = 14.0;
  static const _minRowHeight = 58.0;

  int _linesFor(Placement p) =>
      1 +
      (showBatch ? 1 : 0) +
      (p.staffId != null || p.roomId != null ? 1 : 0);

  double _heightOf(List<Placement> entries) {
    if (entries.isEmpty) return _minRowHeight;
    final text = entries.fold<double>(
      0,
      (h, p) => h + _linesFor(p) * _lineHeight,
    );
    return text + (entries.length - 1) * _dividerHeight + _cellPadding;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = BorderSide(color: theme.colorScheme.outlineVariant);

    // day → slot → what sits there, worked out once instead of once per cell.
    final byCell = <String, List<Placement>>{};
    for (final p in placements) {
      byCell.putIfAbsent('${p.day}:${p.slotId}', () => []).add(p);
    }
    List<Placement> at(int day, SlotRef slot) => byCell['$day:${slot.id}'] ?? const [];

    final rowHeights = <String, double>{
      for (final slot in problem.slots)
        slot.id: [
          _minRowHeight,
          for (final day in problem.days) _heightOf(at(day, slot)),
        ].reduce((a, b) => a > b ? a : b),
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 32),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Frozen: the period times.
          Column(
            children: [
              Container(
                width: _slotWidth,
                height: _headerHeight,
                color: _section.band(context),
              ),
              for (final slot in problem.slots)
                Container(
                  width: _slotWidth,
                  height: rowHeights[slot.id],
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: _section.tint(context),
                    border: Border(top: line),
                  ),
                  child: Text(
                    slot.label,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: _section.onTint(context)),
                  ),
                ),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      for (final day in problem.days)
                        Container(
                          width: _cellWidth,
                          height: _headerHeight,
                          alignment: Alignment.center,
                          color: _section.band(context),
                          margin: const EdgeInsets.only(left: 1),
                          child: Text(
                            bengaliWeek[day]!,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: _section.onTint(context),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  for (final slot in problem.slots)
                    Row(
                      children: [
                        for (final day in problem.days)
                          _Cell(
                            problem: problem,
                            showBatch: showBatch,
                            width: _cellWidth,
                            height: rowHeights[slot.id]!,
                            border: line,
                            entries: at(day, slot),
                            onTap: () => onTap(day, slot),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.problem,
    required this.entries,
    required this.showBatch,
    required this.width,
    required this.height,
    required this.border,
    required this.onTap,
  });

  final RoutineProblem problem;

  /// More than one when several batches of the class run at the same time,
  /// which is the normal case and exactly what a merged sheet must show.
  final List<Placement> entries;
  final bool showBatch;
  final double width;
  final double height;
  final BorderSide border;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      child: Container(
        width: width,
        height: height,
        margin: const EdgeInsets.only(left: 1),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          border: Border(top: border),
          color: entries.isEmpty ? null : _section.tint(context),
        ),
        child: entries.isEmpty
            ? Center(
                child: Icon(Icons.add,
                    size: 15, color: theme.colorScheme.outlineVariant),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0)
                      Divider(height: 9, color: theme.colorScheme.outlineVariant),
                    Text(
                      problem.nameOfSubject(entries[i].subjectId),
                      maxLines: 1,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        height: 1.25,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (showBatch)
                      Text(
                        problem.nameOfBatch(entries[i].batchId),
                        maxLines: 1,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: _section.onTint(context),
                          height: 1.3,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (entries[i].staffId != null || entries[i].roomId != null)
                      Text(
                        [
                          if (entries[i].staffId != null)
                            problem.nameOfStaff(entries[i].staffId!),
                          if (entries[i].roomId != null)
                            problem.nameOfRoom(entries[i].roomId!),
                        ].join(' · '),
                        maxLines: 1,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline,
                          height: 1.3,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _VersionPicker extends ConsumerWidget {
  const _VersionPicker({required this.onOpen});
  final ValueChanged<RoutineVersion> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(activeSessionProvider).value;

    return Scaffold(
      appBar: SectionAppBar(
        section: _section,
        title: 'Routine',
        actions: [
          IconButton(
            tooltip: 'What the builder needs',
            icon: const Icon(Icons.checklist_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RoutineSetupScreen(
                  onReady: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: session == null
          ? null
          : FloatingActionButton.extended(
              backgroundColor: _section.colour,
              foregroundColor: Colors.white,
              onPressed: () async {
                final version = await ref.read(routineProvider).createVersion(
                      sessionId: session.id,
                      name: 'Routine ${DateTime.now().year}',
                    );
                onOpen(version);
              },
              icon: const Icon(Icons.add),
              label: const Text('New routine'),
            ),
      body: session == null
          ? const Center(child: CircularProgressIndicator())
          : StreamBuilder<List<RoutineVersion>>(
              stream: ref.watch(routineProvider).watchVersions(session.id),
              builder: (context, snapshot) {
                final versions = snapshot.data;
                if (versions == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (versions.isEmpty) {
                  return EmptyState(
                    section: _section,
                    title: 'No routine yet',
                    body: 'The app will ask you a few questions — how many '
                        'teachers, how many periods a day, how often each '
                        'subject meets — then fill in as much of the grid as '
                        'it can and leave the rest for you.',
                    action: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: _section.colour),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => RoutineSetupScreen(
                            onReady: () => Navigator.of(context).pop(),
                          ),
                        ),
                      ),
                      child: const Text('Start'),
                    ),
                  );
                }
                return ListView(
                  children: [
                    for (final version in versions)
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _section.tint(context),
                          foregroundColor: _section.onTint(context),
                          child: const Icon(Icons.grid_on_outlined, size: 19),
                        ),
                        title: Text(version.name),
                        subtitle:
                            Text(version.isPublished ? 'Published' : 'Draft'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => onOpen(version),
                      ),
                  ],
                );
              },
            ),
    );
  }
}
