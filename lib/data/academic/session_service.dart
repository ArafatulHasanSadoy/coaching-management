import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';

/// What a rollover would do, shown before it happens.
class RolloverPlan {
  const RolloverPlan({
    required this.fromSession,
    required this.batches,
    required this.studentCount,
  });

  final AcademicSession fromSession;

  /// Batches that will be recreated in the new session.
  final List<StudentBatch> batches;
  final int studentCount;
}

/// Moving a centre from one academic year to the next.
///
/// Without this, year two means re-entering every student — which is where a
/// centre stops using the app. The important property is that last year is not
/// touched: its batches, invoices and attendance stay exactly as they were, and
/// the new session gets fresh copies. A promotion that rewrote history would
/// make every past receipt unverifiable.
class SessionService {
  const SessionService({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  Future<List<AcademicSession>> all() => (db.select(db.academicSessions)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.desc(t.startDate)]))
      .get();

  Future<AcademicSession?> active() => (db.select(db.academicSessions)
        ..where((t) => t.isActive.equals(true) & t.deletedAt.isNull())
        ..limit(1))
      .getSingleOrNull();

  /// Makes one session the current one. Exactly one is active at a time.
  Future<void> activate(AcademicSession session) async {
    await db.transaction(() async {
      await db.update(db.academicSessions).write(
            const AcademicSessionsCompanion(isActive: Value(false)),
          );
      await (db.update(db.academicSessions)
            ..where((t) => t.id.equals(session.id)))
          .write(
        AcademicSessionsCompanion(
          isActive: const Value(true),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await db.recordChange(
        entity: 'academic_sessions',
        entityId: session.id,
        op: ChangeOp.update,
        deviceId: deviceId,
        action: 'session_activated',
        after: {'name': session.name},
      );
    });
  }

  Future<RolloverPlan> planRollover(AcademicSession from) async {
    final batches = await (db.select(db.batches)
          ..where((t) => t.sessionId.equals(from.id) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();

    final enrolled = await (db.select(db.enrollments)
          ..where((t) =>
              t.sessionId.equals(from.id) &
              t.isActive.equals(true) &
              t.deletedAt.isNull()))
        .get();

    return RolloverPlan(
      fromSession: from,
      batches: batches,
      studentCount: enrolled.map((e) => e.studentId).toSet().length,
    );
  }

  /// Creates the next session and carries the chosen batches into it.
  ///
  /// [batchMapping] says which old batch becomes which new batch name — Class 9
  /// becomes Class 10, and a batch left out is simply not carried forward
  /// (its students finished).
  Future<AcademicSession> rollOver({
    required AcademicSession from,
    required String newName,
    required DateTime startDate,
    required DateTime endDate,
    required Map<String, String> batchMapping,
    bool activateNew = true,
  }) async {
    return db.transaction(() async {
      final session = await db.into(db.academicSessions).insertReturning(
            AcademicSessionsCompanion.insert(
              name: newName,
              startDate: startDate,
              endDate: endDate,
              deviceId: deviceId,
            ),
          );

      var carried = 0;
      for (final entry in batchMapping.entries) {
        final old = await (db.select(db.batches)
              ..where((t) => t.id.equals(entry.key)))
            .getSingleOrNull();
        if (old == null) continue;

        final fresh = await db.into(db.batches).insertReturning(
              BatchesCompanion.insert(
                sessionId: session.id,
                classId: old.classId,
                name: entry.value,
                status: BatchStatus.active,
                deviceId: deviceId,
                groupName: Value(old.groupName),
                capacity: Value(old.capacity),
                monthlyFee: Value(old.monthlyFee),
                defaultRoomId: Value(old.defaultRoomId),
              ),
            );

        final enrollments = await (db.select(db.enrollments)
              ..where((t) =>
                  t.batchId.equals(old.id) &
                  t.isActive.equals(true) &
                  t.deletedAt.isNull()))
            .get();

        await db.batch((b) {
          b.insertAll(db.enrollments, [
            for (final e in enrollments)
              EnrollmentsCompanion.insert(
                studentId: e.studentId,
                batchId: fresh.id,
                sessionId: session.id,
                joinDate: startDate,
                deviceId: deviceId,
              ),
          ]);
        });
        carried += enrollments.length;
      }

      if (activateNew) {
        await db.update(db.academicSessions).write(
              const AcademicSessionsCompanion(isActive: Value(false)),
            );
        await (db.update(db.academicSessions)
              ..where((t) => t.id.equals(session.id)))
            .write(const AcademicSessionsCompanion(isActive: Value(true)));
      }

      await db.recordChange(
        entity: 'academic_sessions',
        entityId: session.id,
        op: ChangeOp.insert,
        deviceId: deviceId,
        action: 'rolled_over',
        before: {'from': from.name},
        after: {
          'to': newName,
          'batches': batchMapping.length,
          'studentsCarried': carried,
        },
      );

      return session;
    });
  }
}
