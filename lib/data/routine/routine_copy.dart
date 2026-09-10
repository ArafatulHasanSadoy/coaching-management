import 'routine_model.dart';

/// What happened when one batch's week was copied onto another.
///
/// Reported rather than swallowed: a paste that silently dropped three periods
/// because the other batch does not study that subject is the kind of thing an
/// owner discovers a fortnight later, on a printed sheet.
class CopyOutcome {
  const CopyOutcome({
    required this.placements,
    required this.copied,
    required this.unassigned,
    required this.teacherBusy,
    required this.withoutRoom,
    required this.skipped,
    required this.notes,
  });

  /// The target batch's new week. Replaces whatever it had.
  final List<Placement> placements;

  final int copied;

  /// Placed, but the period is waiting for the owner to name someone.
  ///
  /// Two different problems, and they need different answers: [unassigned]
  /// means nobody has ever been named for that subject, [teacherBusy] means
  /// the right person is already taking another class at that hour.
  int get withoutTeacher => unassigned + teacherBusy;
  final int unassigned;
  final int teacherBusy;
  final int withoutRoom;

  /// Periods that had nowhere to go, because the target batch has no such
  /// subject on its plan.
  final int skipped;

  /// Written for the owner, one line per thing they need to know.
  final List<String> notes;

  bool get isClean => skipped == 0 && withoutTeacher == 0 && withoutRoom == 0;
}

/// Copies one batch's timetable onto another.
///
/// Not a blind clone. The target batch keeps its own internal wiring: where it
/// has already said who teaches a subject, that teacher is used instead of the
/// source batch's. Only when the target has nobody assigned does the source's
/// teacher carry over — and then only if they are actually free at that hour.
///
/// Anything that would clash is left blank rather than forced, which is the
/// same rule the generator follows: a half-filled grid the owner can finish
/// beats a full one that is wrong.
CopyOutcome copyBatchRoutine({
  required RoutineProblem problem,
  required List<Placement> existing,
  required String fromBatchId,
  required String toBatchId,
}) {
  final source = existing.where((p) => p.batchId == fromBatchId).toList()
    ..sort((a, b) {
      final byDay = a.day.compareTo(b.day);
      return byDay != 0 ? byDay : a.slotId.compareTo(b.slotId);
    });

  // Everything that stays put and therefore still occupies teachers and rooms.
  // The target's own old entries are excluded: they are being replaced.
  final others = existing
      .where((p) => p.batchId != fromBatchId && p.batchId != toBatchId)
      .toList();

  final targetRequirements =
      problem.requirements.where((r) => r.batchId == toBatchId).toList();
  final targetSubjectIds = {for (final r in targetRequirements) r.subjectId};
  final teacherOf = {
    for (final r in targetRequirements)
      if (r.staffId != null) r.subjectId: r.staffId!,
  };

  final targetBatch =
      problem.batches.where((b) => b.id == toBatchId).firstOrNull;
  final size = targetBatch?.size ?? 0;

  // Subjects are per class, so the same subject in two classes is two rows.
  // Matching on name is what lets Class 9's week be copied onto Class 10's.
  final byName = <String, String>{};
  for (final id in targetSubjectIds) {
    byName[problem.nameOfSubject(id).trim().toLowerCase()] = id;
  }

  final placed = <Placement>[];
  final notes = <String>[];
  var unassigned = 0;
  var teacherBusy = 0;
  var withoutRoom = 0;
  var skipped = 0;
  final missing = <String>{};

  bool teacherFree(String staffId, String cell) =>
      !others.any((p) => p.staffId == staffId && p.cell == cell) &&
      !placed.any((p) => p.staffId == staffId && p.cell == cell) &&
      !(problem.staffBusy[staffId]?.contains(cell) ?? false);

  bool roomFree(String roomId, String cell) =>
      !others.any((p) => p.roomId == roomId && p.cell == cell) &&
      !placed.any((p) => p.roomId == roomId && p.cell == cell);

  for (final entry in source) {
    final name = problem.nameOfSubject(entry.subjectId).trim().toLowerCase();
    final subjectId = targetSubjectIds.contains(entry.subjectId)
        ? entry.subjectId
        : byName[name];

    if (subjectId == null) {
      skipped++;
      missing.add(problem.nameOfSubject(entry.subjectId));
      continue;
    }

    final cell = entry.cell;

    // The target batch's own choice wins; the source's teacher is the fallback.
    final candidates = <String>[
      if (teacherOf[subjectId] != null) teacherOf[subjectId]!,
      if (entry.staffId != null) entry.staffId!,
    ];
    final staffId = candidates.where((id) => teacherFree(id, cell)).firstOrNull;
    if (candidates.isEmpty) {
      unassigned++;
    } else if (staffId == null) {
      teacherBusy++;
    }

    // Its old room first, since that is usually the right one, then anything
    // else big enough.
    String? roomId;
    if (entry.roomId != null && roomFree(entry.roomId!, cell)) {
      roomId = entry.roomId;
    } else {
      roomId = problem.rooms
          .where((r) => r.capacity >= size && roomFree(r.id, cell))
          .map((r) => r.id)
          .firstOrNull;
    }
    if (roomId == null) withoutRoom++;

    placed.add(
      Placement(
        batchId: toBatchId,
        subjectId: subjectId,
        day: entry.day,
        slotId: entry.slotId,
        staffId: staffId,
        roomId: roomId,
        isPinned: true,
      ),
    );
  }

  final toName = problem.nameOfBatch(toBatchId);
  if (missing.isNotEmpty) {
    notes.add(
      '$skipped period(s) were left out — $toName does not study '
      '${missing.join(', ')}. Add the subject to its weekly plan and copy '
      'again if it should.',
    );
  }
  if (unassigned > 0) {
    notes.add(
      '$unassigned period(s) have no teacher, because nobody is named for '
      'those subjects yet. Set them once under "Subjects each week" and they '
      'will fill in from then on.',
    );
  }
  if (teacherBusy > 0) {
    notes.add(
      '$teacherBusy period(s) have no teacher, because the one who normally '
      'takes them is already in another class at that hour. Tap the cell to '
      'pick someone else.',
    );
  }
  if (withoutRoom > 0) {
    notes.add(
      '$withoutRoom period(s) have no room yet — every room big enough for '
      '$toName is taken at that hour.',
    );
  }
  if (notes.isEmpty) {
    notes.add('Everything copied across cleanly.');
  }

  return CopyOutcome(
    placements: placed,
    copied: placed.length,
    unassigned: unassigned,
    teacherBusy: teacherBusy,
    withoutRoom: withoutRoom,
    skipped: skipped,
    notes: notes,
  );
}
