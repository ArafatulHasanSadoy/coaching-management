import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';

/// Taking the register.
///
/// Built around one number: a teacher standing in front of forty students has
/// about thirty seconds. So a session opens with everyone already marked
/// present and the teacher only touches the exceptions, and the whole class is
/// saved in a single batched write rather than forty round trips.
class AttendanceService {
  const AttendanceService({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  /// Finds today's session for a batch, or starts one.
  Future<ClassSession> openSession({
    required String batchId,
    DateTime? on,
    String? subjectId,
    String? staffId,
    String? slotId,
  }) async {
    final day = on ?? DateTime.now();
    final from = DateTime(day.year, day.month, day.day);
    final to = from.add(const Duration(days: 1));

    final existing = await (db.select(db.classSessions)
          ..where((t) =>
              t.batchId.equals(batchId) &
              t.heldOn.isBiggerOrEqualValue(from) &
              t.heldOn.isSmallerThanValue(to) &
              t.deletedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) return existing;

    return db.into(db.classSessions).insertReturning(
          ClassSessionsCompanion.insert(
            batchId: batchId,
            heldOn: from,
            state: SessionState.held,
            deviceId: deviceId,
            subjectId: Value(subjectId),
            staffId: Value(staffId),
            slotId: Value(slotId),
          ),
        );
  }

  /// What has already been marked for a session.
  Future<Map<String, AttendanceState>> statesFor(String sessionId) async {
    final rows = await (db.select(db.attendanceRecords)
          ..where((t) =>
              t.classSessionId.equals(sessionId) & t.deletedAt.isNull()))
        .get();
    return {for (final r in rows) r.studentId: r.state};
  }

  /// Saves the whole class at once, replacing whatever was there.
  ///
  /// Deletes and reinserts rather than diffing: a class is thirty to fifty
  /// rows, the write is one batch, and the alternative is a merge that can
  /// leave a student silently unmarked.
  Future<void> saveSession({
    required String sessionId,
    required Map<String, AttendanceState> states,
  }) async {
    await db.transaction(() async {
      await (db.delete(db.attendanceRecords)
            ..where((t) => t.classSessionId.equals(sessionId)))
          .go();

      await db.batch((b) {
        b.insertAll(db.attendanceRecords, [
          for (final entry in states.entries)
            AttendanceRecordsCompanion.insert(
              classSessionId: sessionId,
              studentId: entry.key,
              state: entry.value,
              deviceId: deviceId,
            ),
        ]);
      });

      final absent =
          states.values.where((s) => s == AttendanceState.absent).length;

      await db.recordChange(
        entity: 'class_sessions',
        entityId: sessionId,
        op: ChangeOp.update,
        deviceId: deviceId,
        action: 'attendance_saved',
        after: {'marked': states.length, 'absent': absent},
      );
    });
  }

  /// Attendance percentage for one student across a date range.
  Future<({int held, int present, double percent})> summaryFor({
    required String studentId,
    DateTime? from,
    DateTime? to,
  }) async {
    final query = db.select(db.attendanceRecords).join([
      innerJoin(
        db.classSessions,
        db.classSessions.id.equalsExp(db.attendanceRecords.classSessionId),
      ),
    ])
      ..where(db.attendanceRecords.studentId.equals(studentId) &
          db.attendanceRecords.deletedAt.isNull());

    if (from != null) {
      query.where(db.classSessions.heldOn.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      query.where(db.classSessions.heldOn.isSmallerThanValue(to));
    }

    final rows = await query.get();
    final records = rows.map((r) => r.readTable(db.attendanceRecords));
    final held = records.length;
    final present = records
        .where((r) =>
            r.state == AttendanceState.present ||
            r.state == AttendanceState.late)
        .length;

    return (
      held: held,
      present: present,
      percent: held == 0 ? 0.0 : present / held * 100,
    );
  }

  /// Students absent from their last [threshold] consecutive marked classes.
  ///
  /// The list the front desk rings through — a student quietly drifting away is
  /// visible here weeks before they formally drop out.
  Future<List<Student>> consecutivelyAbsent({int threshold = 3}) async {
    final rows = await (db.select(db.attendanceRecords).join([
      innerJoin(
        db.classSessions,
        db.classSessions.id.equalsExp(db.attendanceRecords.classSessionId),
      ),
      innerJoin(
        db.students,
        db.students.id.equalsExp(db.attendanceRecords.studentId),
      ),
    ])
          ..where(db.attendanceRecords.deletedAt.isNull() &
              db.students.deletedAt.isNull())
          ..orderBy([OrderingTerm.desc(db.classSessions.heldOn)]))
        .get();

    final byStudent = <String, (Student, List<AttendanceState>)>{};
    for (final row in rows) {
      final student = row.readTable(db.students);
      byStudent
          .putIfAbsent(student.id, () => (student, <AttendanceState>[]))
          .$2
          .add(row.readTable(db.attendanceRecords).state);
    }

    final flagged = <Student>[];
    for (final (student, states) in byStudent.values) {
      if (states.length < threshold) continue;
      if (states.take(threshold).every((s) => s == AttendanceState.absent)) {
        flagged.add(student);
      }
    }
    return flagged;
  }
}
