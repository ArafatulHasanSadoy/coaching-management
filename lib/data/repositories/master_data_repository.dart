import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';

/// Reads and writes the centre's structural data.
///
/// Every mutation goes through here rather than through drift directly, because
/// each one must also leave an audit row. Scattering `db.into(...)` calls across
/// screens is how audit trails end up with holes in them.
class MasterDataRepository {
  const MasterDataRepository({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  // ---- reads -----------------------------------------------------------
  // All filter out soft-deleted rows. Archiving is the only delete this app
  // performs, and archived rows must stay invisible without disappearing.

  Stream<List<SchoolClass>> watchClasses() => (db.select(db.classes)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
      .watch();

  Stream<List<Subject>> watchSubjects(String classId) => (db.select(db.subjects)
        ..where((t) => t.classId.equals(classId) & t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
      .watch();

  Stream<List<Room>> watchRooms() => (db.select(db.rooms)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .watch();

  Stream<List<TimeSlot>> watchTimeSlots() => (db.select(db.timeSlots)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.startMinute)]))
      .watch();

  Stream<List<StudentBatch>> watchBatches(String sessionId) => (db.select(db.batches)
        ..where((t) => t.sessionId.equals(sessionId) & t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .watch();

  Future<AcademicSession?> activeSession() =>
      (db.select(db.academicSessions)
            ..where((t) => t.isActive.equals(true) & t.deletedAt.isNull())
            ..limit(1))
          .getSingleOrNull();

  Future<Institution?> institution() => (db.select(db.institutions)
        ..where((t) => t.deletedAt.isNull())
        ..limit(1))
      .getSingleOrNull();

  // ---- writes ----------------------------------------------------------

  Future<SchoolClass> addClass(String name, {int? sortOrder}) async {
    // Defaulting every class to 0 left them in whatever order the database
    // happened to return, so a centre's class list reshuffled itself between
    // screens. New classes go to the end unless told otherwise.
    final existing = await watchClasses().first;
    final row = await db.into(db.classes).insertReturning(
          ClassesCompanion.insert(
            name: name,
            deviceId: deviceId,
            sortOrder: Value(sortOrder ?? existing.length),
          ),
        );
    await _audit('classes', row.id, ChangeOp.insert, after: {'name': name});
    return row;
  }

  Future<Room> addRoom(String name, int capacity) async {
    final row = await db.into(db.rooms).insertReturning(
          RoomsCompanion.insert(
            name: name,
            deviceId: deviceId,
            capacity: Value(capacity),
          ),
        );
    await _audit('rooms', row.id, ChangeOp.insert,
        after: {'name': name, 'capacity': capacity});
    return row;
  }

  Future<TimeSlot> addTimeSlot({
    required String label,
    required int startMinute,
    required int endMinute,
  }) async {
    final row = await db.into(db.timeSlots).insertReturning(
          TimeSlotsCompanion.insert(
            startMinute: startMinute,
            endMinute: endMinute,
            deviceId: deviceId,
            label: Value(label),
            sortOrder: Value(startMinute),
          ),
        );
    await _audit('time_slots', row.id, ChangeOp.insert,
        after: {'label': label, 'start': startMinute, 'end': endMinute});
    return row;
  }

  Future<StudentBatch> addBatch({
    required String sessionId,
    required String classId,
    required String name,
    String groupName = '',
    int capacity = 30,
    int monthlyFee = 0,
    String? defaultRoomId,
  }) async {
    final row = await db.into(db.batches).insertReturning(
          BatchesCompanion.insert(
            sessionId: sessionId,
            classId: classId,
            name: name,
            status: BatchStatus.active,
            deviceId: deviceId,
            groupName: Value(groupName),
            capacity: Value(capacity),
            monthlyFee: Value(monthlyFee),
            defaultRoomId: Value(defaultRoomId),
          ),
        );
    await _audit('batches', row.id, ChangeOp.insert, after: {
      'name': name,
      'capacity': capacity,
      'monthlyFee': monthlyFee,
    });
    return row;
  }

  /// Archives rather than deletes.
  ///
  /// A class or batch that vanished would take its history with it — the
  /// students who sat in it, the fees they paid. Soft deletion keeps the
  /// records answerable while removing the row from every list.
  Future<void> archiveBatch(StudentBatch batch, {String? reason}) async {
    await (db.update(db.batches)..where((t) => t.id.equals(batch.id))).write(
      BatchesCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
        status: const Value(BatchStatus.archived),
      ),
    );
    await _audit(
      'batches',
      batch.id,
      ChangeOp.softDelete,
      before: {'name': batch.name, 'status': batch.status.name},
      after: {'status': BatchStatus.archived.name, 'reason': reason ?? ''},
      action: 'archived',
    );
  }

  Future<void> _audit(
    String entity,
    String id,
    ChangeOp op, {
    Map<String, Object?>? before,
    Map<String, Object?>? after,
    String action = '',
  }) =>
      db.recordChange(
        entity: entity,
        entityId: id,
        op: op,
        deviceId: deviceId,
        before: before,
        after: after,
        action: action,
      );

  // ---- editing and archiving -------------------------------------------
  //
  // Stage 2 could create these but never change them. Archiving rather than
  // deleting throughout: a room or a period that vanished would orphan the
  // routine entries and attendance that referred to it.

  Future<void> renameClass(SchoolClass row, String name) async {
    await (db.update(db.classes)..where((t) => t.id.equals(row.id))).write(
      ClassesCompanion(name: Value(name), updatedAt: Value(DateTime.now())),
    );
    await _audit('classes', row.id, ChangeOp.update,
        before: {'name': row.name}, after: {'name': name}, action: 'renamed');
  }

  Future<void> archiveClass(SchoolClass row) async {
    await (db.update(db.classes)..where((t) => t.id.equals(row.id))).write(
      ClassesCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await _audit('classes', row.id, ChangeOp.softDelete,
        before: {'name': row.name}, action: 'archived');
  }

  Future<Subject> addSubject({
    required String classId,
    required String name,
    String shortName = '',
    int weeklyClasses = 2,
  }) async {
    final existing = await watchSubjects(classId).first;
    final row = await db.into(db.subjects).insertReturning(
          SubjectsCompanion.insert(
            classId: classId,
            name: name,
            deviceId: deviceId,
            shortName: Value(shortName),
            weeklyClasses: Value(weeklyClasses),
            sortOrder: Value(existing.length),
          ),
        );
    await _audit('subjects', row.id, ChangeOp.insert,
        after: {'name': name, 'weekly': weeklyClasses});
    return row;
  }

  Future<void> updateSubject(
    Subject row, {
    String? name,
    String? shortName,
    int? weeklyClasses,
  }) async {
    await (db.update(db.subjects)..where((t) => t.id.equals(row.id))).write(
      SubjectsCompanion(
        name: Value(name ?? row.name),
        shortName: Value(shortName ?? row.shortName),
        weeklyClasses: Value(weeklyClasses ?? row.weeklyClasses),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await _audit('subjects', row.id, ChangeOp.update,
        before: {'name': row.name, 'weekly': row.weeklyClasses},
        after: {'name': name ?? row.name, 'weekly': weeklyClasses ?? row.weeklyClasses},
        action: 'edited');
  }

  Future<void> archiveSubject(Subject row) async {
    await (db.update(db.subjects)..where((t) => t.id.equals(row.id))).write(
      SubjectsCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await _audit('subjects', row.id, ChangeOp.softDelete,
        before: {'name': row.name}, action: 'archived');
  }

  Future<void> updateRoom(Room row, {String? name, int? capacity}) async {
    await (db.update(db.rooms)..where((t) => t.id.equals(row.id))).write(
      RoomsCompanion(
        name: Value(name ?? row.name),
        capacity: Value(capacity ?? row.capacity),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await _audit('rooms', row.id, ChangeOp.update,
        before: {'name': row.name, 'capacity': row.capacity},
        after: {'name': name ?? row.name, 'capacity': capacity ?? row.capacity},
        action: 'edited');
  }

  Future<void> archiveRoom(Room row) async {
    await (db.update(db.rooms)..where((t) => t.id.equals(row.id))).write(
      RoomsCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await _audit('rooms', row.id, ChangeOp.softDelete,
        before: {'name': row.name}, action: 'archived');
  }

  Future<void> updateTimeSlot(
    TimeSlot row, {
    String? label,
    int? startMinute,
    int? endMinute,
  }) async {
    await (db.update(db.timeSlots)..where((t) => t.id.equals(row.id))).write(
      TimeSlotsCompanion(
        label: Value(label ?? row.label),
        startMinute: Value(startMinute ?? row.startMinute),
        endMinute: Value(endMinute ?? row.endMinute),
        sortOrder: Value(startMinute ?? row.startMinute),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await _audit('time_slots', row.id, ChangeOp.update,
        before: {'label': row.label}, after: {'label': label ?? row.label},
        action: 'edited');
  }

  Future<void> archiveTimeSlot(TimeSlot row) async {
    await (db.update(db.timeSlots)..where((t) => t.id.equals(row.id))).write(
      TimeSlotsCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await _audit('time_slots', row.id, ChangeOp.softDelete,
        before: {'label': row.label}, action: 'archived');
  }

  Future<void> updateBatch(
    StudentBatch row, {
    String? name,
    String? groupName,
    int? capacity,
    int? monthlyFee,
    String? defaultRoomId,
  }) async {
    await (db.update(db.batches)..where((t) => t.id.equals(row.id))).write(
      BatchesCompanion(
        name: Value(name ?? row.name),
        groupName: Value(groupName ?? row.groupName),
        capacity: Value(capacity ?? row.capacity),
        monthlyFee: Value(monthlyFee ?? row.monthlyFee),
        defaultRoomId: Value(defaultRoomId ?? row.defaultRoomId),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await _audit('batches', row.id, ChangeOp.update,
        before: {'name': row.name, 'fee': row.monthlyFee},
        after: {'name': name ?? row.name, 'fee': monthlyFee ?? row.monthlyFee},
        action: 'edited');
  }

  /// Updates the centre's own details, so the wizard is not the only chance to
  /// get them right.
  Future<void> updateInstitution(
    Institution row, {
    String? name,
    String? address,
    String? phone,
    String? email,
    String? receiptFooter,
    String? signatureName,
    String? studentIdPattern,
  }) async {
    await (db.update(db.institutions)..where((t) => t.id.equals(row.id))).write(
      InstitutionsCompanion(
        name: Value(name ?? row.name),
        address: Value(address ?? row.address),
        phone: Value(phone ?? row.phone),
        email: Value(email ?? row.email),
        receiptFooter: Value(receiptFooter ?? row.receiptFooter),
        signatureName: Value(signatureName ?? row.signatureName),
        studentIdPattern: Value(studentIdPattern ?? row.studentIdPattern),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await _audit('institutions', row.id, ChangeOp.update,
        before: {'name': row.name}, after: {'name': name ?? row.name},
        action: 'profile_edited');
  }
}
