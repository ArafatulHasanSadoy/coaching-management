import 'routine_model.dart';

/// A legal thing that could occupy an empty slot.
class Candidate {
  const Candidate({
    required this.batchId,
    required this.subjectId,
    required this.staffId,
    required this.roomId,
    required this.remaining,
  });

  final String batchId;
  final String subjectId;
  final String? staffId;
  final String? roomId;

  /// Periods of this subject still owed to this batch. Higher first.
  final int remaining;
}

/// Checks placements and answers "what can go here?".
///
/// The distinction between hard and soft runs through everything: a hard
/// conflict is a physical impossibility — one person, two rooms, one moment —
/// and cannot be saved. A soft one is a preference the administration can
/// knowingly override, because they routinely need to. Refusing a double period
/// before an exam would make the app wrong, not careful.
abstract final class RoutineEngine {
  /// Everything wrong with putting [candidate] into the grid alongside
  /// [existing]. Empty means it fits.
  static List<Conflict> conflictsFor({
    required RoutineProblem problem,
    required Placement candidate,
    required List<Placement> existing,
    RequirementRef? requirement,
  }) {
    final conflicts = <Conflict>[];
    final cell = candidate.cell;
    final sameCell = existing.where((p) => p.cell == cell && p != candidate);

    for (final other in sameCell) {
      if (candidate.staffId != null && other.staffId == candidate.staffId) {
        conflicts.add(Conflict(
          kind: ConflictKind.teacherBusy,
          hard: true,
          message: '${problem.nameOfStaff(candidate.staffId!)} already teaches '
              '${problem.nameOfBatch(other.batchId)} at this time.',
        ));
      }
      if (other.batchId == candidate.batchId) {
        conflicts.add(Conflict(
          kind: ConflictKind.batchBusy,
          hard: true,
          message: '${problem.nameOfBatch(candidate.batchId)} already has '
              '${problem.nameOfSubject(other.subjectId)} at this time.',
        ));
      }
      if (candidate.roomId != null && other.roomId == candidate.roomId) {
        conflicts.add(Conflict(
          kind: ConflictKind.roomBusy,
          hard: true,
          message: '${problem.nameOfRoom(candidate.roomId!)} is taken by '
              '${problem.nameOfBatch(other.batchId)}.',
        ));
      }
    }

    if (candidate.staffId != null &&
        (problem.staffBusy[candidate.staffId] ?? const <String>{})
            .contains(cell)) {
      conflicts.add(Conflict(
        kind: ConflictKind.teacherUnavailable,
        hard: true,
        message: '${problem.nameOfStaff(candidate.staffId!)} is not available '
            '${bengaliWeek[candidate.day]} ${problem.nameOfSlot(candidate.slotId)}.',
      ));
    }

    if (candidate.roomId != null) {
      final room = problem.rooms.where((r) => r.id == candidate.roomId).firstOrNull;
      final batch =
          problem.batches.where((b) => b.id == candidate.batchId).firstOrNull;
      if (room != null && batch != null && batch.size > room.capacity) {
        conflicts.add(Conflict(
          kind: ConflictKind.roomTooSmall,
          hard: true,
          message: '${batch.name} has ${batch.size} students; '
              '${room.name} seats ${room.capacity}.',
        ));
      }
    }

    // ---- soft ----

    final allowTwice = requirement?.allowTwiceADay ??
        problem.requirements
            .where((r) =>
                r.batchId == candidate.batchId &&
                r.subjectId == candidate.subjectId)
            .map((r) => r.allowTwiceADay)
            .firstOrNull ??
        false;

    if (!allowTwice) {
      final sameSubjectToday = existing.where((p) =>
          p != candidate &&
          p.day == candidate.day &&
          p.batchId == candidate.batchId &&
          p.subjectId == candidate.subjectId);
      if (sameSubjectToday.isNotEmpty) {
        conflicts.add(Conflict(
          kind: ConflictKind.subjectTwiceADay,
          hard: false,
          message: '${problem.nameOfBatch(candidate.batchId)} would have '
              '${problem.nameOfSubject(candidate.subjectId)} twice on '
              '${bengaliWeek[candidate.day]}.',
        ));
      }
    }

    final batch = problem.batches.where((b) => b.id == candidate.batchId).firstOrNull;
    if (batch != null) {
      final todayCount = existing
          .where((p) =>
              p != candidate && p.day == candidate.day && p.batchId == batch.id)
          .length;
      if (todayCount + 1 > batch.maxPerDay) {
        conflicts.add(Conflict(
          kind: ConflictKind.batchDayFull,
          hard: false,
          message: '${batch.name} would have ${todayCount + 1} classes on '
              '${bengaliWeek[candidate.day]}.',
        ));
      }
    }

    if (candidate.staffId != null) {
      final teacher =
          problem.staff.where((s) => s.id == candidate.staffId).firstOrNull;
      if (teacher != null) {
        final todayCount = existing
            .where((p) =>
                p != candidate &&
                p.day == candidate.day &&
                p.staffId == teacher.id)
            .length;
        if (todayCount + 1 > teacher.maxPerDay) {
          conflicts.add(Conflict(
            kind: ConflictKind.teacherDayFull,
            hard: false,
            message: '${teacher.name} would teach ${todayCount + 1} classes on '
                '${bengaliWeek[candidate.day]}.',
          ));
        }
      }
    }

    return conflicts;
  }

  static bool fits({
    required RoutineProblem problem,
    required Placement candidate,
    required List<Placement> existing,
    RequirementRef? requirement,
  }) =>
      !conflictsFor(
        problem: problem,
        candidate: candidate,
        existing: existing,
        requirement: requirement,
      ).any((c) => c.hard);

  /// What could legally go in one empty cell.
  ///
  /// This is the feature that turns the conflict engine from a validator into
  /// an assistant: instead of the administrator guessing and being told no,
  /// the app offers only what actually fits.
  static List<Candidate> candidatesFor({
    required RoutineProblem problem,
    required int day,
    required String slotId,
    required List<Placement> existing,
    String? roomId,
  }) {
    final placedCounts = <String, int>{};
    for (final p in existing) {
      placedCounts.update('${p.batchId}/${p.subjectId}', (n) => n + 1,
          ifAbsent: () => 1);
    }

    final out = <Candidate>[];
    for (final requirement in problem.requirements) {
      final done = placedCounts[requirement.key] ?? 0;
      final remaining = requirement.periodsPerWeek - done;
      if (remaining <= 0) continue;

      final batch =
          problem.batches.where((b) => b.id == requirement.batchId).firstOrNull;
      final rooms = roomId != null
          ? problem.rooms.where((r) => r.id == roomId)
          : [
              if (batch?.defaultRoomId != null)
                ...problem.rooms.where((r) => r.id == batch!.defaultRoomId),
              ...problem.rooms.where((r) => r.id != batch?.defaultRoomId),
            ];

      for (final room in rooms) {
        final candidate = Placement(
          batchId: requirement.batchId,
          subjectId: requirement.subjectId,
          staffId: requirement.staffId,
          roomId: room.id,
          day: day,
          slotId: slotId,
        );
        if (fits(
          problem: problem,
          candidate: candidate,
          existing: existing,
          requirement: requirement,
        )) {
          out.add(Candidate(
            batchId: requirement.batchId,
            subjectId: requirement.subjectId,
            staffId: requirement.staffId,
            roomId: room.id,
            remaining: remaining,
          ));
          break; // one room suggestion per requirement is enough
        }
      }
    }

    out.sort((a, b) => b.remaining.compareTo(a.remaining));
    return out;
  }

  /// Free cells for one teacher, for answering "when is Mr Rahman available?".
  static List<String> freeCellsFor({
    required RoutineProblem problem,
    required String staffId,
    required List<Placement> existing,
  }) {
    final busy = {
      ...?problem.staffBusy[staffId],
      ...existing.where((p) => p.staffId == staffId).map((p) => p.cell),
    };
    return [
      for (final day in problem.days)
        for (final slot in problem.slots)
          if (!busy.contains('$day:${slot.id}')) '$day:${slot.id}',
    ];
  }

  /// How far a routine is from ideal. Lower is better.
  ///
  /// Counts the things an administrator notices: a teacher with a free period
  /// stranded between two classes, a batch loaded unevenly across the week, the
  /// same subject bunched into consecutive days.
  static int softPenalty(RoutineProblem problem, List<Placement> placements) {
    var penalty = 0;
    final slotOrder = {for (final s in problem.slots) s.id: s.order};

    // Teacher gaps.
    for (final teacher in problem.staff) {
      for (final day in problem.days) {
        final orders = placements
            .where((p) => p.staffId == teacher.id && p.day == day)
            .map((p) => slotOrder[p.slotId] ?? 0)
            .toList()
          ..sort();
        if (orders.length < 2) continue;
        penalty += (orders.last - orders.first + 1) - orders.length;
      }
    }

    // Uneven daily load per batch.
    for (final batch in problem.batches) {
      final perDay = [
        for (final day in problem.days)
          placements.where((p) => p.batchId == batch.id && p.day == day).length,
      ];
      if (perDay.isEmpty) continue;
      final max = perDay.reduce((a, b) => a > b ? a : b);
      final min = perDay.reduce((a, b) => a < b ? a : b);
      penalty += (max - min);
    }

    // The same subject on consecutive days.
    for (final requirement in problem.requirements) {
      final days = placements
          .where((p) =>
              p.batchId == requirement.batchId &&
              p.subjectId == requirement.subjectId)
          .map((p) => p.day)
          .toList()
        ..sort();
      for (var i = 1; i < days.length; i++) {
        if (days[i] - days[i - 1] == 1) penalty += 1;
      }
    }

    return penalty;
  }
}
