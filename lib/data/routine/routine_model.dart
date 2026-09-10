/// Plain data describing a timetabling problem.
///
/// Deliberately free of drift types: the solver runs in an isolate, and only
/// simple values cross that boundary. It also makes the whole engine testable
/// without a database.
library;

/// 1 = Saturday … 7 = Friday, matching how a Bangladeshi week is written.
const bengaliWeek = <int, String>{
  1: 'Saturday',
  2: 'Sunday',
  3: 'Monday',
  4: 'Tuesday',
  5: 'Wednesday',
  6: 'Thursday',
  7: 'Friday',
};

class SlotRef {
  const SlotRef({required this.id, required this.label, required this.order});
  final String id;
  final String label;
  final int order;
}

class BatchRef {
  const BatchRef({
    required this.id,
    required this.name,
    required this.size,
    this.classId = '',
    this.className = '',
    this.defaultRoomId,
    this.maxPerDay = 4,
  });

  final String id;
  final String name;

  /// Which class this batch belongs to.
  ///
  /// The grid is drawn one class at a time with every batch of that class
  /// merged into it — that is how a centre reads a timetable, and how the
  /// owner asked for it. The solver ignores both of these.
  final String classId;
  final String className;

  /// Enrolled headcount, checked against room capacity.
  final int size;
  final String? defaultRoomId;
  final int maxPerDay;
}

class RoomRef {
  const RoomRef({required this.id, required this.name, required this.capacity});
  final String id;
  final String name;
  final int capacity;
}

class StaffRef {
  const StaffRef({
    required this.id,
    required this.name,
    this.maxPerDay = 6,
  });
  final String id;
  final String name;
  final int maxPerDay;
}

class SubjectRef {
  const SubjectRef({required this.id, required this.name});
  final String id;
  final String name;
}

/// "This batch needs three periods of Physics a week, taught by Mr Karim."
class RequirementRef {
  const RequirementRef({
    required this.batchId,
    required this.subjectId,
    required this.periodsPerWeek,
    this.staffId,
    this.allowTwiceADay = false,
  });

  final String batchId;
  final String subjectId;
  final int periodsPerWeek;
  final String? staffId;
  final bool allowTwiceADay;

  String get key => '$batchId/$subjectId';
}

/// One class placed in the grid.
class Placement {
  const Placement({
    required this.batchId,
    required this.subjectId,
    required this.day,
    required this.slotId,
    this.staffId,
    this.roomId,
    this.isPinned = false,
  });

  final String batchId;
  final String subjectId;
  final int day;
  final String slotId;
  final String? staffId;
  final String? roomId;
  final bool isPinned;

  String get cell => '$day:$slotId';

  Placement copyWith({String? roomId, String? staffId, int? day, String? slotId}) =>
      Placement(
        batchId: batchId,
        subjectId: subjectId,
        day: day ?? this.day,
        slotId: slotId ?? this.slotId,
        staffId: staffId ?? this.staffId,
        roomId: roomId ?? this.roomId,
        isPinned: isPinned,
      );
}

/// The whole problem, in one sendable object.
class RoutineProblem {
  const RoutineProblem({
    required this.days,
    required this.slots,
    required this.batches,
    required this.rooms,
    required this.staff,
    required this.subjects,
    required this.requirements,
    this.staffBusy = const {},
    this.pinned = const [],
  });

  final List<int> days;
  final List<SlotRef> slots;
  final List<BatchRef> batches;
  final List<RoomRef> rooms;
  final List<StaffRef> staff;
  final List<SubjectRef> subjects;
  final List<RequirementRef> requirements;

  /// staffId → cells (`day:slotId`) they cannot teach in.
  final Map<String, Set<String>> staffBusy;

  /// Placements the solver must keep exactly where they are.
  final List<Placement> pinned;

  String nameOfBatch(String id) =>
      batches.where((b) => b.id == id).map((b) => b.name).firstOrNull ?? id;
  String nameOfSubject(String id) =>
      subjects.where((s) => s.id == id).map((s) => s.name).firstOrNull ?? id;
  String nameOfStaff(String id) =>
      staff.where((s) => s.id == id).map((s) => s.name).firstOrNull ?? id;
  String nameOfRoom(String id) =>
      rooms.where((r) => r.id == id).map((r) => r.name).firstOrNull ?? id;
  String nameOfSlot(String id) =>
      slots.where((s) => s.id == id).map((s) => s.label).firstOrNull ?? id;
}

/// Why something clashes.
enum ConflictKind {
  teacherBusy,
  batchBusy,
  roomBusy,
  teacherUnavailable,
  roomTooSmall,
  subjectTwiceADay,
  batchDayFull,
  teacherDayFull,
}

class Conflict {
  const Conflict({
    required this.kind,
    required this.hard,
    required this.message,
  });

  final ConflictKind kind;

  /// Hard conflicts make a routine invalid. Soft ones are preferences the
  /// administration can knowingly override — and often needs to.
  final bool hard;
  final String message;
}

/// A requirement the solver could not fully satisfy.
class Unplaced {
  const Unplaced({
    required this.requirement,
    required this.wanted,
    required this.placed,
    required this.reason,
    required this.suggestions,
  });

  final RequirementRef requirement;
  final int wanted;
  final int placed;

  /// Written for the administrator, not for a log file.
  final String reason;
  final List<String> suggestions;
}

class SolveResult {
  const SolveResult({
    required this.placements,
    required this.unplaced,
    required this.softPenalty,
    required this.attempts,
  });

  final List<Placement> placements;
  final List<Unplaced> unplaced;

  /// Lower is better. Counts gaps, uneven loads and clustered subjects.
  final int softPenalty;
  final int attempts;

  int get requiredTotal => placements.length + unplaced.fold(0, (n, u) => n + (u.wanted - u.placed));

  /// How much of what was asked for got scheduled.
  double get completeness =>
      requiredTotal == 0 ? 100 : placements.length / requiredTotal * 100;

  bool get isComplete => unplaced.isEmpty;
}
