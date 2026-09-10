import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';
import 'routine_copy.dart';
import 'routine_model.dart';

/// Loads a timetabling problem out of the database and writes the answer back.
///
/// Kept separate from the engine so the engine stays plain Dart — testable
/// without a database and sendable to an isolate.
class RoutineRepository {
  const RoutineRepository({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  Stream<List<RoutineVersion>> watchVersions(String sessionId) =>
      (db.select(db.routineVersions)
            ..where((t) => t.sessionId.equals(sessionId) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<RoutineVersion> createVersion({
    required String sessionId,
    required String name,
  }) async {
    final row = await db.into(db.routineVersions).insertReturning(
          RoutineVersionsCompanion.insert(
            sessionId: sessionId,
            name: name,
            deviceId: deviceId,
          ),
        );
    await db.recordChange(
      entity: 'routine_versions',
      entityId: row.id,
      op: ChangeOp.insert,
      deviceId: deviceId,
      action: 'routine_created',
      after: {'name': name},
    );
    return row;
  }

  Stream<List<RoutineEntry>> watchEntries(String versionId) =>
      (db.select(db.routineEntries)
            ..where((t) =>
                t.routineVersionId.equals(versionId) & t.deletedAt.isNull()))
          .watch();

  /// Builds the solver's view of the centre.
  ///
  /// Batch size comes from live enrolment rather than the batch's capacity
  /// field: capacity is what the centre hopes for, enrolment is who actually
  /// has to fit in the room.
  Future<RoutineProblem> loadProblem({
    required String sessionId,
    required String versionId,
    List<int> days = const [1, 2, 3, 4, 5, 6],
  }) async {
    final slots = await (db.select(db.timeSlots)
          ..where((t) => t.deletedAt.isNull() & t.isActive.equals(true))
          ..orderBy([(t) => OrderingTerm.asc(t.startMinute)]))
        .get();

    final rooms = await (db.select(db.rooms)
          ..where((t) => t.deletedAt.isNull() & t.isActive.equals(true)))
        .get();

    final batches = await (db.select(db.batches)
          ..where((t) => t.sessionId.equals(sessionId) & t.deletedAt.isNull()))
        .get();

    final classRows = await (db.select(db.classes)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
    final classNames = {for (final c in classRows) c.id: c.name};
    final classOrder = {
      for (var i = 0; i < classRows.length; i++) classRows[i].id: i,
    };

    final staff = await (db.select(db.staff)
          ..where((t) => t.deletedAt.isNull() & t.isActive.equals(true)))
        .get();

    final subjects = await (db.select(db.subjects)
          ..where((t) => t.deletedAt.isNull()))
        .get();

    final requirements = await (db.select(db.subjectRequirements)
          ..where((t) => t.deletedAt.isNull()))
        .get();

    final availability = await (db.select(db.staffAvailability)
          ..where((t) =>
              t.deletedAt.isNull() & t.isAvailable.equals(false)))
        .get();

    final enrollments = await (db.select(db.enrollments)
          ..where((t) =>
              t.sessionId.equals(sessionId) &
              t.isActive.equals(true) &
              t.deletedAt.isNull()))
        .get();

    final headcount = <String, int>{};
    for (final e in enrollments) {
      headcount.update(e.batchId, (n) => n + 1, ifAbsent: () => 1);
    }

    final pinned = await (db.select(db.routineEntries)
          ..where((t) =>
              t.routineVersionId.equals(versionId) &
              t.isPinned.equals(true) &
              t.deletedAt.isNull()))
        .get();

    final busy = <String, Set<String>>{};
    for (final row in availability) {
      busy.putIfAbsent(row.staffId, () => <String>{})
          .add('${row.dayOfWeek}:${row.slotId}');
    }

    return RoutineProblem(
      days: days,
      slots: [
        for (var i = 0; i < slots.length; i++)
          SlotRef(
            id: slots[i].id,
            label: slots[i].label.isEmpty ? 'Period ${i + 1}' : slots[i].label,
            order: i,
          ),
      ],
      batches: [
        // Ordered by class so the grid's class list reads 6, 7, 8 … rather
        // than in whatever order batches happened to be created.
        for (final b in (batches.toList()
          ..sort((a, b) {
            final byClass = (classOrder[a.classId] ?? 99)
                .compareTo(classOrder[b.classId] ?? 99);
            return byClass != 0 ? byClass : a.name.compareTo(b.name);
          })))
          BatchRef(
            id: b.id,
            name: b.name,
            size: headcount[b.id] ?? 0,
            classId: b.classId,
            className: classNames[b.classId] ?? 'Class',
            defaultRoomId: b.defaultRoomId,
          ),
      ],
      rooms: [
        for (final r in rooms)
          RoomRef(id: r.id, name: r.name, capacity: r.capacity),
      ],
      staff: [for (final s in staff) StaffRef(id: s.id, name: s.name)],
      subjects: [
        for (final s in subjects) SubjectRef(id: s.id, name: s.name),
      ],
      requirements: [
        for (final r in requirements)
          RequirementRef(
            batchId: r.batchId,
            subjectId: r.subjectId,
            staffId: r.staffId,
            periodsPerWeek: r.periodsPerWeek,
            allowTwiceADay: r.allowTwiceADay,
          ),
      ],
      staffBusy: busy,
      pinned: [
        for (final p in pinned)
          Placement(
            batchId: p.batchId,
            subjectId: p.subjectId,
            staffId: p.staffId,
            roomId: p.roomId,
            day: p.dayOfWeek,
            slotId: p.slotId,
            isPinned: true,
          ),
      ],
    );
  }

  /// Replaces a version's unpinned entries with [placements].
  ///
  /// Pinned entries survive: they are the ones a human deliberately put where
  /// they are, and a regenerate that moved them would be the app overruling
  /// the administration.
  Future<void> savePlacements({
    required String versionId,
    required List<Placement> placements,
  }) async {
    await db.transaction(() async {
      await (db.delete(db.routineEntries)
            ..where((t) =>
                t.routineVersionId.equals(versionId) &
                t.isPinned.equals(false)))
          .go();

      await db.batch((b) {
        b.insertAll(db.routineEntries, [
          for (final p in placements)
            if (!p.isPinned)
              RoutineEntriesCompanion.insert(
                routineVersionId: versionId,
                batchId: p.batchId,
                subjectId: p.subjectId,
                slotId: p.slotId,
                dayOfWeek: p.day,
                deviceId: deviceId,
                staffId: Value(p.staffId),
                roomId: Value(p.roomId),
              ),
        ]);
      });

      await db.recordChange(
        entity: 'routine_versions',
        entityId: versionId,
        op: ChangeOp.update,
        deviceId: deviceId,
        action: 'routine_generated',
        after: {'placed': placements.length},
      );
    });
  }

  Future<RoutineEntry> addEntry({
    required String versionId,
    required Placement placement,
    bool pinned = true,
  }) =>
      db.into(db.routineEntries).insertReturning(
            RoutineEntriesCompanion.insert(
              routineVersionId: versionId,
              batchId: placement.batchId,
              subjectId: placement.subjectId,
              slotId: placement.slotId,
              dayOfWeek: placement.day,
              deviceId: deviceId,
              staffId: Value(placement.staffId),
              roomId: Value(placement.roomId),
              isPinned: Value(pinned),
            ),
          );

  Future<void> removeEntry(RoutineEntry entry) =>
      (db.update(db.routineEntries)..where((t) => t.id.equals(entry.id))).write(
        RoutineEntriesCompanion(
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );

  /// Replaces one batch's whole week with a copy of another batch's.
  ///
  /// Destructive for the target batch by design — "paste over" is what the
  /// owner means — but it touches nothing else in the version.
  Future<CopyOutcome> copyBatch({
    required String versionId,
    required RoutineProblem problem,
    required String fromBatchId,
    required String toBatchId,
  }) async {
    final entries = await (db.select(db.routineEntries)
          ..where((t) =>
              t.routineVersionId.equals(versionId) & t.deletedAt.isNull()))
        .get();

    final outcome = copyBatchRoutine(
      problem: problem,
      existing: [
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
      ],
      fromBatchId: fromBatchId,
      toBatchId: toBatchId,
    );

    await db.transaction(() async {
      await (db.update(db.routineEntries)
            ..where((t) =>
                t.routineVersionId.equals(versionId) &
                t.batchId.equals(toBatchId) &
                t.deletedAt.isNull()))
          .write(
        RoutineEntriesCompanion(
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );

      await db.batch((batch) {
        batch.insertAll(db.routineEntries, [
          for (final p in outcome.placements)
            RoutineEntriesCompanion.insert(
              routineVersionId: versionId,
              batchId: p.batchId,
              subjectId: p.subjectId,
              slotId: p.slotId,
              dayOfWeek: p.day,
              deviceId: deviceId,
              staffId: Value(p.staffId),
              roomId: Value(p.roomId),
              isPinned: const Value(true),
            ),
        ]);
      });
    });

    await db.recordChange(
      entity: 'routine_versions',
      entityId: versionId,
      op: ChangeOp.update,
      deviceId: deviceId,
      action: 'routine_copied',
      after: {
        'from': fromBatchId,
        'to': toBatchId,
        'copied': outcome.copied,
        'skipped': outcome.skipped,
      },
    );

    return outcome;
  }

  /// Clears one cell of one batch's timetable.
  ///
  /// The grid knows a placement by where it sits, not by its row id, so this
  /// takes the same coordinates the user tapped.
  Future<void> removeAt({
    required String versionId,
    required String batchId,
    required int day,
    required String slotId,
  }) =>
      (db.update(db.routineEntries)
            ..where((t) =>
                t.routineVersionId.equals(versionId) &
                t.batchId.equals(batchId) &
                t.dayOfWeek.equals(day) &
                t.slotId.equals(slotId) &
                t.deletedAt.isNull()))
          .write(
        RoutineEntriesCompanion(
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );

  /// Ensures every batch has a weekly requirement per subject of its class,
  /// seeded from the subject's own `weeklyClasses`.
  ///
  /// Without this the solver has nothing to place, and asking an administrator
  /// to type a requirement row per batch per subject before seeing anything
  /// work is how the feature goes unused.
  Future<int> seedRequirements(String sessionId) async {
    final batches = await (db.select(db.batches)
          ..where((t) => t.sessionId.equals(sessionId) & t.deletedAt.isNull()))
        .get();

    // Deliberately includes rows the owner has removed: seeding is
    // "has this batch ever been offered this subject", not "does it have one
    // now". Without that, a subject dropped from a batch would come back
    // every time the routine screen opened.
    final existing = await db.select(db.subjectRequirements).get();
    final seen = {for (final r in existing) '${r.batchId}/${r.subjectId}'};

    var created = 0;
    for (final batch in batches) {
      final subjects = await (db.select(db.subjects)
            ..where((t) =>
                t.classId.equals(batch.classId) & t.deletedAt.isNull()))
          .get();

      for (final subject in subjects) {
        if (seen.contains('${batch.id}/${subject.id}')) continue;
        await db.into(db.subjectRequirements).insert(
              SubjectRequirementsCompanion.insert(
                batchId: batch.id,
                subjectId: subject.id,
                deviceId: deviceId,
                periodsPerWeek: Value(subject.weeklyClasses),
              ),
            );
        created++;
      }
    }
    return created;
  }
}
