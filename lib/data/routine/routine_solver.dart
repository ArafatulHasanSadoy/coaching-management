import 'dart:math';

import 'routine_engine.dart';
import 'routine_model.dart';

enum SolveMode {
  /// Place everything legally, as quickly as possible.
  fast,

  /// Then spend a bounded amount of effort making it pleasant to teach.
  balanced,
}

/// One sendable message, because the solver runs in an isolate.
class SolveRequest {
  const SolveRequest({
    required this.problem,
    this.mode = SolveMode.balanced,
    this.seed = 20260910,
  });

  final RoutineProblem problem;
  final SolveMode mode;

  /// Fixed by default so the same input produces the same routine. An
  /// administrator who presses Generate twice and gets two different answers
  /// stops trusting it.
  final int seed;
}

/// Builds a timetable.
///
/// Top-level so it can be handed to `compute` — a centre with twenty batches is
/// a few hundred thousand placement checks, and doing that on the UI thread
/// would freeze the phone mid-generation.
///
/// The approach is deliberately not a general CSP library: most-constrained
/// first, greedy placement scored by how much soft penalty each cell adds, then
/// min-conflicts local search in balanced mode. It is easy to reason about, it
/// terminates, and — most importantly — when it cannot place something it can
/// still say *why*, which a black-box solver cannot.
SolveResult solveRoutine(SolveRequest request) {
  final problem = request.problem;
  final random = Random(request.seed);

  final placements = <Placement>[
    for (final p in problem.pinned)
      Placement(
        batchId: p.batchId,
        subjectId: p.subjectId,
        staffId: p.staffId,
        roomId: p.roomId,
        day: p.day,
        slotId: p.slotId,
        isPinned: true,
      ),
  ];

  // How many periods of each requirement the pinned entries already cover.
  final covered = <String, int>{};
  for (final p in placements) {
    covered.update('${p.batchId}/${p.subjectId}', (n) => n + 1,
        ifAbsent: () => 1);
  }

  // One work item per period still owed.
  final pending = <RequirementRef>[];
  for (final requirement in problem.requirements) {
    final already = covered[requirement.key] ?? 0;
    for (var i = 0; i < requirement.periodsPerWeek - already; i++) {
      pending.add(requirement);
    }
  }

  final cells = <(int, SlotRef)>[
    for (final day in problem.days)
      for (final slot in problem.slots) (day, slot),
  ];

  /// Every cell this requirement could legally occupy right now.
  List<(Placement, int)> feasible(RequirementRef requirement) {
    final batch =
        problem.batches.where((b) => b.id == requirement.batchId).firstOrNull;
    final rooms = <RoomRef>[
      if (batch?.defaultRoomId != null)
        ...problem.rooms.where((r) => r.id == batch!.defaultRoomId),
      ...problem.rooms.where((r) => r.id != batch?.defaultRoomId),
    ];

    final options = <(Placement, int)>[];
    for (final (day, slot) in cells) {
      for (final room in rooms) {
        final candidate = Placement(
          batchId: requirement.batchId,
          subjectId: requirement.subjectId,
          staffId: requirement.staffId,
          roomId: room.id,
          day: day,
          slotId: slot.id,
        );
        final conflicts = RoutineEngine.conflictsFor(
          problem: problem,
          candidate: candidate,
          existing: placements,
          requirement: requirement,
        );
        if (conflicts.any((c) => c.hard)) continue;

        // Soft conflicts do not block, they cost.
        final cost = conflicts.length * 4 +
            RoutineEngine.softPenalty(problem, [...placements, candidate]);
        options.add((candidate, cost));
        break; // first room that fits is enough; others only add noise
      }
    }
    return options;
  }

  // Most-constrained first: whatever has the fewest homes gets one before the
  // easy cases eat them.
  pending.sort((a, b) => feasible(a).length.compareTo(feasible(b).length));

  final unplaced = <Unplaced>[];
  final placedPerRequirement = <String, int>{...covered};
  var attempts = 0;

  for (final requirement in pending) {
    final options = feasible(requirement);
    attempts += options.length;

    if (options.isEmpty) {
      final existing = unplaced.indexWhere(
          (u) => u.requirement.key == requirement.key);
      if (existing >= 0) {
        final u = unplaced[existing];
        unplaced[existing] = Unplaced(
          requirement: u.requirement,
          wanted: u.wanted,
          placed: u.placed,
          reason: u.reason,
          suggestions: u.suggestions,
        );
      } else {
        final diagnosis = _diagnose(problem, requirement, placements, cells);
        unplaced.add(Unplaced(
          requirement: requirement,
          wanted: requirement.periodsPerWeek,
          placed: placedPerRequirement[requirement.key] ?? 0,
          reason: diagnosis.$1,
          suggestions: diagnosis.$2,
        ));
      }
      continue;
    }

    options.sort((a, b) => a.$2.compareTo(b.$2));
    // Break ties randomly so a tidy grid does not always stack into Saturday.
    final best = options.first.$2;
    final tied = options.where((o) => o.$2 == best).toList();
    placements.add(tied[random.nextInt(tied.length)].$1);
    placedPerRequirement.update(requirement.key, (n) => n + 1,
        ifAbsent: () => 1);
  }

  if (request.mode == SolveMode.balanced) {
    _improve(problem, placements, random, cells);
  }

  return SolveResult(
    placements: placements,
    unplaced: unplaced,
    softPenalty: RoutineEngine.softPenalty(problem, placements),
    attempts: attempts,
  );
}

/// Min-conflicts local search, bounded so generation always ends.
void _improve(
  RoutineProblem problem,
  List<Placement> placements,
  Random random,
  List<(int, SlotRef)> cells,
) {
  final movable = [
    for (var i = 0; i < placements.length; i++)
      if (!placements[i].isPinned) i,
  ];
  if (movable.isEmpty) return;

  var current = RoutineEngine.softPenalty(problem, placements);
  const rounds = 400;

  for (var round = 0; round < rounds && current > 0; round++) {
    final index = movable[random.nextInt(movable.length)];
    final original = placements[index];
    final (day, slot) = cells[random.nextInt(cells.length)];
    if (day == original.day && slot.id == original.slotId) continue;

    final moved = original.copyWith(day: day, slotId: slot.id);
    final others = [...placements]..removeAt(index);

    final conflicts = RoutineEngine.conflictsFor(
      problem: problem,
      candidate: moved,
      existing: others,
    );
    if (conflicts.any((c) => c.hard)) continue;

    final trial = [...others, moved];
    final penalty =
        RoutineEngine.softPenalty(problem, trial) + conflicts.length * 4;
    if (penalty < current) {
      placements[index] = moved;
      current = penalty;
    }
  }
}

/// Works out, in words, why a requirement had nowhere to go.
///
/// "Routine generation failed" tells an administrator nothing they can act on.
/// This walks every cell, records which hard constraint rejected it, and
/// reports the one that did the most damage along with what would fix it.
(String, List<String>) _diagnose(
  RoutineProblem problem,
  RequirementRef requirement,
  List<Placement> placements,
  List<(int, SlotRef)> cells,
) {
  final counts = <ConflictKind, int>{};
  final batch =
      problem.batches.where((b) => b.id == requirement.batchId).firstOrNull;

  for (final (day, slot) in cells) {
    for (final room in problem.rooms) {
      final conflicts = RoutineEngine.conflictsFor(
        problem: problem,
        candidate: Placement(
          batchId: requirement.batchId,
          subjectId: requirement.subjectId,
          staffId: requirement.staffId,
          roomId: room.id,
          day: day,
          slotId: slot.id,
        ),
        existing: placements,
        requirement: requirement,
      );
      for (final c in conflicts.where((c) => c.hard)) {
        counts.update(c.kind, (n) => n + 1, ifAbsent: () => 1);
      }
    }
  }

  final batchName = problem.nameOfBatch(requirement.batchId);
  final subjectName = problem.nameOfSubject(requirement.subjectId);
  final teacherName = requirement.staffId == null
      ? null
      : problem.nameOfStaff(requirement.staffId!);

  if (counts.isEmpty) {
    return (
      'There was no free period left for $subjectName in $batchName.',
      ['Add another period to the day', 'Reduce the periods required'],
    );
  }

  final dominant =
      counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

  return switch (dominant) {
    ConflictKind.teacherUnavailable => (
        '${teacherName ?? 'The teacher'} is not available in any period that '
            '$batchName still has free.',
        [
          'Widen ${teacherName ?? 'the teacher'}’s availability',
          'Assign a different teacher to $subjectName',
          'Move another class to free an earlier period',
        ],
      ),
    ConflictKind.teacherBusy => (
        '${teacherName ?? 'The teacher'} is already teaching in every period '
            '$batchName has free.',
        [
          'Assign a second teacher to $subjectName',
          'Move one of ${teacherName ?? 'their'} other classes',
          'Open another period in the day',
        ],
      ),
    ConflictKind.roomBusy => (
        'Every room is occupied in the periods $batchName has free.',
        [
          'Add another room',
          'Move a class that does not need its room',
          'Open another period in the day',
        ],
      ),
    ConflictKind.roomTooSmall => (
        '$batchName (${batch?.size ?? '?'} students) does not fit in any room '
            'free at those times.',
        [
          'Use a larger room',
          'Split $batchName into two batches',
          'Raise the capacity recorded for a room',
        ],
      ),
    ConflictKind.batchBusy => (
        '$batchName already has a class in every period.',
        ['Open another period in the day', 'Reduce periods for another subject'],
      ),
    _ => (
        'No period could be found for $subjectName in $batchName.',
        ['Open another period in the day', 'Review the weekly requirements'],
      ),
  };
}
