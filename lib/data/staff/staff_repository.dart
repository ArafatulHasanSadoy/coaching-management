import 'package:drift/drift.dart';

import '../../core/phone.dart';
import '../db/database.dart';
import '../db/tables.dart';

/// Everything about one teacher, gathered for their profile page.
class TeacherProfile {
  const TeacherProfile({
    required this.staff,
    required this.classes,
    required this.subjects,
    required this.classesTaughtThisMonth,
    required this.paidToDate,
    required this.recentPayments,
  });

  final StaffMember staff;
  final List<SchoolClass> classes;
  final List<Subject> subjects;
  final int classesTaughtThisMonth;
  final int paidToDate;
  final List<SalaryPayment> recentPayments;
}

/// Teachers and office staff.
///
/// Kept apart because they answer different questions: a teacher has classes,
/// subjects and a rate that depends on how much they taught; an office worker
/// has a salary and a job. Mixing them into one list makes both harder to read.
class StaffRepository {
  const StaffRepository({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  Stream<List<StaffMember>> watchTeachers() => (db.select(db.staff)
        ..where((t) =>
            t.deletedAt.isNull() &
            t.isActive.equals(true) &
            t.isTeacher.equals(true))
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .watch();

  Stream<List<StaffMember>> watchOtherStaff() => (db.select(db.staff)
        ..where((t) =>
            t.deletedAt.isNull() &
            t.isActive.equals(true) &
            t.isTeacher.equals(false))
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .watch();

  Future<StaffMember> add({
    required String name,
    required bool isTeacher,
    String phone = '',
    String role = '',
    int monthlySalary = 0,
    int perClassRate = 0,
    int hourlyRate = 0,
    PayModel payModel = PayModel.monthly,
    DateTime? joinDate,
  }) async {
    final row = await db.into(db.staff).insertReturning(
          StaffCompanion.insert(
            name: name.trim(),
            joinDate: joinDate ?? DateTime.now(),
            payModel: payModel,
            deviceId: deviceId,
            phone: Value(phone.trim()),
            phoneNorm: Value(Phone.normalize(phone)),
            role: Value(role.isEmpty ? (isTeacher ? 'Teacher' : 'Staff') : role),
            monthlySalary: Value(monthlySalary),
            perClassRate: Value(perClassRate),
            hourlyRate: Value(hourlyRate),
            isTeacher: Value(isTeacher),
          ),
        );

    await db.recordChange(
      entity: 'staff',
      entityId: row.id,
      op: ChangeOp.insert,
      deviceId: deviceId,
      action: isTeacher ? 'teacher_added' : 'staff_added',
      after: {'name': name, 'role': row.role},
    );
    return row;
  }

  Future<void> update(
    StaffMember member, {
    String? name,
    String? phone,
    String? role,
    int? monthlySalary,
    int? perClassRate,
    int? hourlyRate,
    PayModel? payModel,
    bool? isTeacher,
  }) async {
    final newPhone = phone ?? member.phone;
    await (db.update(db.staff)..where((t) => t.id.equals(member.id))).write(
      StaffCompanion(
        name: Value(name ?? member.name),
        phone: Value(newPhone),
        phoneNorm: Value(Phone.normalize(newPhone)),
        role: Value(role ?? member.role),
        monthlySalary: Value(monthlySalary ?? member.monthlySalary),
        perClassRate: Value(perClassRate ?? member.perClassRate),
        hourlyRate: Value(hourlyRate ?? member.hourlyRate),
        payModel: Value(payModel ?? member.payModel),
        isTeacher: Value(isTeacher ?? member.isTeacher),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await db.recordChange(
      entity: 'staff',
      entityId: member.id,
      op: ChangeOp.update,
      deviceId: deviceId,
      action: 'edited',
      before: {'name': member.name},
      after: {'name': name ?? member.name},
    );
  }

  // ---- which classes a teacher takes ----------------------------------

  Future<List<SchoolClass>> classesOf(String staffId) async {
    final links = await (db.select(db.staffClasses)
          ..where((t) => t.staffId.equals(staffId) & t.deletedAt.isNull()))
        .get();
    if (links.isEmpty) return const [];

    return (db.select(db.classes)
          ..where((t) =>
              t.id.isIn(links.map((l) => l.classId).toList()) &
              t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
  }

  /// Replaces the set of classes a teacher takes.
  Future<void> setClasses(String staffId, List<String> classIds) async {
    await db.transaction(() async {
      await (db.delete(db.staffClasses)..where((t) => t.staffId.equals(staffId)))
          .go();
      await db.batch((b) {
        b.insertAll(db.staffClasses, [
          for (final classId in classIds)
            StaffClassesCompanion.insert(
              staffId: staffId,
              classId: classId,
              deviceId: deviceId,
            ),
        ]);
      });
      await db.recordChange(
        entity: 'staff',
        entityId: staffId,
        op: ChangeOp.update,
        deviceId: deviceId,
        action: 'classes_set',
        after: {'count': classIds.length},
      );
    });
  }

  Future<List<Subject>> subjectsOf(String staffId) async {
    final links = await (db.select(db.staffSubjects)
          ..where((t) => t.staffId.equals(staffId) & t.deletedAt.isNull()))
        .get();
    if (links.isEmpty) return const [];

    return (db.select(db.subjects)
          ..where((t) =>
              t.id.isIn(links.map((l) => l.subjectId).toList()) &
              t.deletedAt.isNull()))
        .get();
  }

  Future<void> setSubjects(String staffId, List<String> subjectIds) async {
    await db.transaction(() async {
      await (db.delete(db.staffSubjects)
            ..where((t) => t.staffId.equals(staffId)))
          .go();
      await db.batch((b) {
        b.insertAll(db.staffSubjects, [
          for (final subjectId in subjectIds)
            StaffSubjectsCompanion.insert(
              staffId: staffId,
              subjectId: subjectId,
              deviceId: deviceId,
            ),
        ]);
      });
    });
  }

  /// Everything the teacher's own page shows.
  Future<TeacherProfile> profileOf(StaffMember member, {DateTime? month}) async {
    final when = month ?? DateTime.now();
    final from = DateTime(when.year, when.month);
    final to = DateTime(when.year, when.month + 1);

    final sessions = await (db.select(db.classSessions)
          ..where((t) =>
              t.staffId.equals(member.id) &
              t.heldOn.isBiggerOrEqualValue(from) &
              t.heldOn.isSmallerThanValue(to) &
              t.state.equalsValue(SessionState.held) &
              t.deletedAt.isNull()))
        .get();

    final payments = await (db.select(db.salaryPayments)
          ..where((t) =>
              t.staffId.equals(member.id) &
              t.isCancelled.equals(false) &
              t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.paidOn)]))
        .get();

    return TeacherProfile(
      staff: member,
      classes: await classesOf(member.id),
      subjects: await subjectsOf(member.id),
      classesTaughtThisMonth: sessions.length,
      paidToDate: payments.fold(0, (sum, p) => sum + p.netAmount),
      recentPayments: payments.take(20).toList(),
    );
  }

  /// A teacher's month, counted both ways.
  ///
  /// The owner asked for classes *and* hours because the two answer different
  /// questions: "did they turn up for what they were rostered" and "how much
  /// extra teaching did they do". Showing only the pay figure hides both.
  Future<List<TeacherAttendance>> attendanceFor(DateTime month) async {
    final from = DateTime(month.year, month.month);
    final to = DateTime(month.year, month.month + 1);

    final teachers = await (db.select(db.staff)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.isActive.equals(true) &
              t.isTeacher.equals(true))
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();

    final sessions = await (db.select(db.classSessions)
          ..where((t) =>
              t.heldOn.isBiggerOrEqualValue(from) &
              t.heldOn.isSmallerThanValue(to) &
              t.state.equalsValue(SessionState.held) &
              t.deletedAt.isNull()))
        .get();

    final marked = await (db.select(db.staffAttendance)
          ..where((t) =>
              t.onDate.isBiggerOrEqualValue(from) &
              t.onDate.isSmallerThanValue(to) &
              t.deletedAt.isNull()))
        .get();

    return [
      for (final teacher in teachers)
        () {
          final mine = sessions.where((s) => s.staffId == teacher.id);
          final theirDays = marked.where((m) => m.staffId == teacher.id);
          return TeacherAttendance(
            staff: teacher,
            regularClasses:
                mine.where((s) => s.kind == SessionKind.regular).length,
            extraMinutes: mine
                .where((s) => s.kind == SessionKind.extra)
                .fold(0, (sum, s) => sum + s.durationMinutes),
            daysPresent: theirDays
                .where((m) =>
                    m.state == AttendanceState.present ||
                    m.state == AttendanceState.late)
                .length,
            daysAbsent: theirDays
                .where((m) => m.state == AttendanceState.absent)
                .length,
          );
        }(),
    ];
  }
}

/// How much a teacher taught in a month, counted both ways.
class TeacherAttendance {
  const TeacherAttendance({
    required this.staff,
    required this.regularClasses,
    required this.extraMinutes,
    required this.daysPresent,
    required this.daysAbsent,
  });

  final StaffMember staff;

  /// Routine classes taken — the class-wise count.
  final int regularClasses;

  /// Extra sittings, in minutes — the hourly count.
  final int extraMinutes;

  final int daysPresent;
  final int daysAbsent;

  double get extraHours => extraMinutes / 60;

  /// Rendered the way it would be said aloud: "3 h 30 m".
  String get extraHoursLabel {
    if (extraMinutes == 0) return '—';
    final hours = extraMinutes ~/ 60;
    final minutes = extraMinutes % 60;
    if (hours == 0) return '$minutes m';
    if (minutes == 0) return '$hours h';
    return '$hours h $minutes m';
  }
}
