import 'package:drift/drift.dart';

import '../../core/phone.dart';
import '../db/database.dart';
import '../db/tables.dart';
import 'student_code.dart';

/// A student who may be the same person as one being admitted.
class DuplicateCandidate {
  const DuplicateCandidate({required this.student, required this.reason});

  final Student student;

  /// Why this was flagged, phrased for the person at the desk.
  final String reason;
}

/// Everything the app does with students.
class StudentsRepository {
  const StudentsRepository({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  // ---- reads -----------------------------------------------------------

  Stream<List<Student>> watchStudents({StudentStatus? status}) {
    final query = db.select(db.students)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.asc(t.name)]);
    if (status != null) query.where((t) => t.status.equalsValue(status));
    return query.watch();
  }

  /// Finds students by name, code, or phone.
  ///
  /// Phone is checked first and as a prefix, because a number typed at the desk
  /// is almost always a parent calling and is the single most common lookup.
  /// A digits-only query is never treated as a name — nobody is called 01712.
  Future<List<Student>> search(String rawQuery, {int limit = 30}) async {
    final query = rawQuery.trim();
    if (query.isEmpty) return const [];

    final digits = query.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 3 && digits.length == query.replaceAll(RegExp(r'[\s\-+]'), '').length) {
      final prefix = Phone.normalize(query);
      final pattern = '${prefix.isEmpty ? digits : prefix}%';
      return (db.select(db.students)
            ..where((t) =>
                t.deletedAt.isNull() &
                (t.guardianPhoneNorm.like(pattern) |
                    t.studentPhoneNorm.like(pattern)))
            ..limit(limit))
          .get();
    }

    final like = '%${query.toLowerCase()}%';
    return (db.select(db.students)
          ..where((t) =>
              t.deletedAt.isNull() &
              (t.name.lower().like(like) |
                  t.nameAlt.lower().like(like) |
                  t.code.lower().like(like) |
                  t.guardianName.lower().like(like)))
          ..limit(limit))
        .get();
    }

  /// Students who might already be the person about to be admitted.
  ///
  /// Run before creating a record rather than as a unique constraint, because
  /// siblings legitimately share a guardian's number — the desk has to decide,
  /// so the app surfaces the evidence instead of refusing.
  Future<List<DuplicateCandidate>> findDuplicates({
    required String name,
    String guardianPhone = '',
    String studentPhone = '',
  }) async {
    final candidates = <String, DuplicateCandidate>{};

    for (final (raw, label) in [
      (guardianPhone, "the same guardian's number"),
      (studentPhone, 'the same student number'),
    ]) {
      final norm = Phone.normalize(raw);
      if (norm.isEmpty) continue;
      final matches = await (db.select(db.students)
            ..where((t) =>
                t.deletedAt.isNull() &
                (t.guardianPhoneNorm.equals(norm) |
                    t.studentPhoneNorm.equals(norm))))
          .get();
      for (final m in matches) {
        candidates[m.id] = DuplicateCandidate(student: m, reason: 'Has $label');
      }
    }

    final trimmed = name.trim().toLowerCase();
    if (trimmed.length >= 3) {
      final byName = await (db.select(db.students)
            ..where((t) => t.deletedAt.isNull() & t.name.lower().equals(trimmed))
            ..limit(10))
          .get();
      for (final m in byName) {
        candidates.putIfAbsent(
          m.id,
          () => DuplicateCandidate(
            student: m,
            reason: 'Has exactly the same name',
          ),
        );
      }
    }

    return candidates.values.toList();
  }

  /// The code the next admission would receive.
  Future<String> nextCode({DateTime? when}) async {
    final institution = await (db.select(db.institutions)
          ..where((t) => t.deletedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
    final pattern = institution?.studentIdPattern ?? '{YY}-{#####}';
    final codes = await db.students.select().map((s) => s.code).get();
    return StudentCode.next(
      pattern: pattern,
      when: when ?? DateTime.now(),
      existingCodes: codes,
    );
  }

  // ---- writes ----------------------------------------------------------

  /// Admits a student and enrols them in a batch, as one operation.
  ///
  /// A student row without its enrolment would be invisible everywhere that
  /// matters — batch lists, attendance, fee generation — so the two are written
  /// together or not at all.
  Future<Student> admit({
    required String name,
    required String batchId,
    required String sessionId,
    String nameAlt = '',
    String guardianName = '',
    String guardianRelation = '',
    String guardianPhone = '',
    String studentPhone = '',
    String school = '',
    String address = '',
    String bloodGroup = '',
    String referredBy = '',
    String notes = '',
    Gender? gender,
    DateTime? dateOfBirth,
    DateTime? admissionDate,
    String? code,
    int monthlyFee = 0,
    Map<String, String> customFields = const {},
  }) async {
    final when = admissionDate ?? DateTime.now();

    return db.transaction(() async {
      final student = await db.into(db.students).insertReturning(
            StudentsCompanion.insert(
              code: code ?? await nextCode(when: when),
              name: name.trim(),
              admissionDate: when,
              status: StudentStatus.active,
              deviceId: deviceId,
              nameAlt: Value(nameAlt.trim()),
              guardianName: Value(guardianName.trim()),
              guardianRelation: Value(guardianRelation.trim()),
              guardianPhone: Value(guardianPhone.trim()),
              guardianPhoneNorm: Value(Phone.normalize(guardianPhone)),
              studentPhone: Value(studentPhone.trim()),
              studentPhoneNorm: Value(Phone.normalize(studentPhone)),
              school: Value(school.trim()),
              address: Value(address.trim()),
              bloodGroup: Value(bloodGroup.trim()),
              referredBy: Value(referredBy.trim()),
              notes: Value(notes.trim()),
              gender: Value(gender),
              dateOfBirth: Value(dateOfBirth),
              monthlyFee: Value(monthlyFee),
            ),
          );

      // The centre's own admission-form answers, stored alongside the record.
      if (customFields.isNotEmpty) {
        await db.batch((b) {
          b.insertAll(db.studentFieldValues, [
            for (final entry in customFields.entries)
              if (entry.value.trim().isNotEmpty)
                StudentFieldValuesCompanion.insert(
                  studentId: student.id,
                  fieldId: entry.key,
                  deviceId: deviceId,
                  value: Value(entry.value.trim()),
                ),
          ]);
        });
      }

      await db.into(db.enrollments).insert(
            EnrollmentsCompanion.insert(
              studentId: student.id,
              batchId: batchId,
              sessionId: sessionId,
              joinDate: when,
              deviceId: deviceId,
            ),
          );

      await db.recordChange(
        entity: 'students',
        entityId: student.id,
        op: ChangeOp.insert,
        deviceId: deviceId,
        action: 'admitted',
        after: {
          'code': student.code,
          'name': student.name,
          'batchId': batchId,
          'monthlyFee': monthlyFee,
        },
      );

      return student;
    });
  }

  /// The batch a student is currently enrolled in, if any.
  Future<Enrollment?> activeEnrollment(String studentId) =>
      (db.select(db.enrollments)
            ..where((t) =>
                t.studentId.equals(studentId) &
                t.isActive.equals(true) &
                t.deletedAt.isNull())
            ..limit(1))
          .getSingleOrNull();

  Stream<List<Student>> watchBatchRoster(String batchId) {
    final query = db.select(db.students).join([
      innerJoin(
        db.enrollments,
        db.enrollments.studentId.equalsExp(db.students.id) &
            db.enrollments.batchId.equals(batchId) &
            db.enrollments.isActive.equals(true) &
            db.enrollments.deletedAt.isNull(),
      ),
    ])
      ..where(db.students.deletedAt.isNull())
      ..orderBy([OrderingTerm.asc(db.students.name)]);
    return query.map((row) => row.readTable(db.students)).watch();
  }

  /// Updates a student's details.
  ///
  /// Rewrites the normalised phone columns alongside the raw ones — they are a
  /// cache of the same fact, and letting them drift would silently break the
  /// search the front desk relies on.
  Future<void> update(
    Student student, {
    String? name,
    String? nameAlt,
    String? guardianName,
    String? guardianRelation,
    String? guardianPhone,
    String? studentPhone,
    String? school,
    String? address,
    String? bloodGroup,
    String? notes,
    String? photoPath,
    Gender? gender,
    DateTime? dateOfBirth,
    int? monthlyFee,
  }) async {
    final guardian = guardianPhone ?? student.guardianPhone;
    final own = studentPhone ?? student.studentPhone;

    await db.transaction(() async {
      await (db.update(db.students)..where((t) => t.id.equals(student.id)))
          .write(
        StudentsCompanion(
          name: Value(name ?? student.name),
          nameAlt: Value(nameAlt ?? student.nameAlt),
          guardianName: Value(guardianName ?? student.guardianName),
          guardianRelation: Value(guardianRelation ?? student.guardianRelation),
          guardianPhone: Value(guardian),
          guardianPhoneNorm: Value(Phone.normalize(guardian)),
          studentPhone: Value(own),
          studentPhoneNorm: Value(Phone.normalize(own)),
          school: Value(school ?? student.school),
          address: Value(address ?? student.address),
          bloodGroup: Value(bloodGroup ?? student.bloodGroup),
          notes: Value(notes ?? student.notes),
          photoPath: Value(photoPath ?? student.photoPath),
          gender: Value(gender ?? student.gender),
          dateOfBirth: Value(dateOfBirth ?? student.dateOfBirth),
          monthlyFee: Value(monthlyFee ?? student.monthlyFee),
          updatedAt: Value(DateTime.now()),
        ),
      );

      await _audit(student.id, ChangeOp.update, 'edited',
          before: {'name': student.name, 'phone': student.guardianPhone},
          after: {'name': name ?? student.name, 'phone': guardian});
    });
  }

  /// Moves a student to another batch.
  ///
  /// The old enrolment is closed rather than rewritten, so the fees and
  /// attendance that belong to their time in the previous batch stay attached
  /// to it.
  Future<void> transferBatch({
    required Student student,
    required String toBatchId,
    required String sessionId,
    DateTime? on,
    String reason = '',
  }) async {
    final when = on ?? DateTime.now();

    await db.transaction(() async {
      final current = await activeEnrollment(student.id);
      if (current != null) {
        if (current.batchId == toBatchId) return;
        await (db.update(db.enrollments)
              ..where((t) => t.id.equals(current.id)))
            .write(
          EnrollmentsCompanion(
            isActive: const Value(false),
            leaveDate: Value(when),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }

      await db.into(db.enrollments).insert(
            EnrollmentsCompanion.insert(
              studentId: student.id,
              batchId: toBatchId,
              sessionId: sessionId,
              joinDate: when,
              deviceId: deviceId,
            ),
          );

      await _audit(student.id, ChangeOp.update, 'transferred',
          before: {'batchId': current?.batchId},
          after: {'batchId': toBatchId, 'reason': reason});
    });
  }

  /// Changes a student's standing — dropped out, completed, returned.
  Future<void> setStatus(
    Student student,
    StudentStatus status, {
    String reason = '',
  }) async {
    await db.transaction(() async {
      await (db.update(db.students)..where((t) => t.id.equals(student.id)))
          .write(
        StudentsCompanion(
          status: Value(status),
          updatedAt: Value(DateTime.now()),
        ),
      );

      // A student who has left should stop appearing in batch rosters and
      // attendance, but their record and history stay.
      if (status == StudentStatus.dropped ||
          status == StudentStatus.completed) {
        await (db.update(db.enrollments)
              ..where((t) =>
                  t.studentId.equals(student.id) & t.isActive.equals(true)))
            .write(
          EnrollmentsCompanion(
            isActive: const Value(false),
            leaveDate: Value(DateTime.now()),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }

      await _audit(student.id, ChangeOp.update, 'status_changed',
          before: {'status': student.status.name},
          after: {'status': status.name, 'reason': reason});
    });
  }

  /// Records that two students are siblings.
  ///
  /// Written both ways, so opening either child shows the other. A family
  /// discount and a guardian phone call both start from knowing the pair.
  Future<void> linkSiblings(String a, String b,
      {String relation = 'sibling'}) async {
    if (a == b) return;
    await db.transaction(() async {
      for (final (from, to) in [(a, b), (b, a)]) {
        final existing = await (db.select(db.studentLinks)
              ..where((t) =>
                  t.studentId.equals(from) &
                  t.relatedStudentId.equals(to) &
                  t.deletedAt.isNull()))
            .getSingleOrNull();
        if (existing != null) continue;

        await db.into(db.studentLinks).insert(
              StudentLinksCompanion.insert(
                studentId: from,
                relatedStudentId: to,
                deviceId: deviceId,
                relation: Value(relation),
              ),
            );
      }
      await _audit(a, ChangeOp.insert, 'sibling_linked', after: {'with': b});
    });
  }

  Future<List<Student>> siblingsOf(String studentId) async {
    final links = await (db.select(db.studentLinks)
          ..where((t) => t.studentId.equals(studentId) & t.deletedAt.isNull()))
        .get();
    if (links.isEmpty) return const [];

    final ids = links.map((l) => l.relatedStudentId).toList();
    return (db.select(db.students)
          ..where((t) => t.id.isIn(ids) & t.deletedAt.isNull()))
        .get();
  }

  /// The register, narrowed.
  Stream<List<Student>> watchFiltered({
    StudentStatus? status,
    String? batchId,
    String? classId,
  }) {
    if (batchId == null && classId == null) {
      return watchStudents(status: status);
    }

    final query = db.select(db.students).join([
      innerJoin(
        db.enrollments,
        db.enrollments.studentId.equalsExp(db.students.id) &
            db.enrollments.isActive.equals(true) &
            db.enrollments.deletedAt.isNull(),
      ),
      innerJoin(db.batches, db.batches.id.equalsExp(db.enrollments.batchId)),
    ])
      ..where(db.students.deletedAt.isNull())
      ..orderBy([OrderingTerm.asc(db.students.name)]);

    if (status != null) query.where(db.students.status.equalsValue(status));
    if (batchId != null) query.where(db.batches.id.equals(batchId));
    if (classId != null) query.where(db.batches.classId.equals(classId));

    return query.map((row) => row.readTable(db.students)).watch();
  }

  Future<void> _audit(
    String id,
    ChangeOp op,
    String action, {
    Map<String, Object?>? before,
    Map<String, Object?>? after,
  }) =>
      db.recordChange(
        entity: 'students',
        entityId: id,
        op: op,
        deviceId: deviceId,
        action: action,
        before: before,
        after: after,
      );

  /// The register grouped by class.
  ///
  /// A flat alphabetical list of six hundred names is not how a centre thinks
  /// about its students — it thinks in classes, and so should the screen.
  /// Students with no active enrolment are grouped under a null key rather than
  /// dropped, because a student who is not in a batch is exactly the one
  /// somebody needs to notice.
  Stream<Map<SchoolClass?, List<Student>>> watchByClass(String sessionId) {
    final query = db.select(db.students).join([
      leftOuterJoin(
        db.enrollments,
        db.enrollments.studentId.equalsExp(db.students.id) &
            db.enrollments.isActive.equals(true) &
            db.enrollments.sessionId.equals(sessionId) &
            db.enrollments.deletedAt.isNull(),
      ),
      leftOuterJoin(db.batches, db.batches.id.equalsExp(db.enrollments.batchId)),
      leftOuterJoin(db.classes, db.classes.id.equalsExp(db.batches.classId)),
    ])
      ..where(db.students.deletedAt.isNull() &
          db.students.status.equalsValue(StudentStatus.active))
      ..orderBy([OrderingTerm.asc(db.students.name)]);

    return query.watch().map((rows) {
      final grouped = <String, (SchoolClass?, List<Student>)>{};
      for (final row in rows) {
        final schoolClass = row.readTableOrNull(db.classes);
        final key = schoolClass?.id ?? '';
        grouped
            .putIfAbsent(key, () => (schoolClass, <Student>[]))
            .$2
            .add(row.readTable(db.students));
      }

      final ordered = grouped.values.toList()
        ..sort((a, b) {
          // Unassigned students last, so the classes read in their own order.
          if (a.$1 == null) return 1;
          if (b.$1 == null) return -1;
          return a.$1!.sortOrder.compareTo(b.$1!.sortOrder);
        });

      return {for (final (schoolClass, list) in ordered) schoolClass: list};
    });
  }
}
