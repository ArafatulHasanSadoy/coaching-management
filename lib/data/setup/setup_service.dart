import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';
import '../defaults/curriculum_defaults.dart';

/// What the wizard collected.
class SetupPlan {
  const SetupPlan({
    required this.centreName,
    required this.address,
    required this.phone,
    required this.sessionName,
    required this.sessionStart,
    required this.sessionEnd,
    required this.selectedClasses,
    required this.banglaSubjectNames,
    required this.includeDefaultRooms,
    required this.includeDefaultTimeSlots,
    this.email = '',
    this.receiptFooter = '',
    this.signatureName = '',
  });

  final String centreName;
  final String address;
  final String phone;
  final String email;
  final String receiptFooter;
  final String signatureName;

  final String sessionName;
  final DateTime sessionStart;
  final DateTime sessionEnd;

  final List<DefaultClass> selectedClasses;
  final bool banglaSubjectNames;
  final bool includeDefaultRooms;
  final bool includeDefaultTimeSlots;
}

/// Summary of what setup created, shown on the finish screen so the owner can
/// see the result rather than being told "Done".
class SetupResult {
  const SetupResult({
    required this.classes,
    required this.subjects,
    required this.rooms,
    required this.timeSlots,
  });

  final int classes;
  final int subjects;
  final int rooms;
  final int timeSlots;
}

/// Turns a [SetupPlan] into rows.
///
/// The whole thing runs in one transaction. A setup that half-succeeded would
/// leave a centre with classes but no session, or subjects pointing at a class
/// that was never written — states no screen in the app is built to handle, and
/// which the owner could only escape by wiping their data.
class SetupService {
  const SetupService();

  Future<SetupResult> apply({
    required AppDatabase db,
    required SetupPlan plan,
    required String deviceId,
  }) async {
    return db.transaction(() async {
      final institution = await db.into(db.institutions).insertReturning(
            InstitutionsCompanion.insert(
              name: plan.centreName,
              deviceId: deviceId,
              address: Value(plan.address),
              phone: Value(plan.phone),
              email: Value(plan.email),
              receiptFooter: Value(plan.receiptFooter),
              signatureName: Value(plan.signatureName),
            ),
          );

      await db.into(db.academicSessions).insert(
            AcademicSessionsCompanion.insert(
              name: plan.sessionName,
              startDate: plan.sessionStart,
              endDate: plan.sessionEnd,
              deviceId: deviceId,
              isActive: const Value(true),
            ),
          );

      var subjectCount = 0;
      for (var i = 0; i < plan.selectedClasses.length; i++) {
        final source = plan.selectedClasses[i];
        final created = await db.into(db.classes).insertReturning(
              ClassesCompanion.insert(
                name: source.label,
                deviceId: deviceId,
                sortOrder: Value(i),
              ),
            );

        for (var j = 0; j < source.subjects.length; j++) {
          final subject = source.subjects[j];
          await db.into(db.subjects).insert(
                SubjectsCompanion.insert(
                  classId: created.id,
                  name: subject.name(bangla: plan.banglaSubjectNames),
                  deviceId: deviceId,
                  shortName:
                      Value(subject.shortName(bangla: plan.banglaSubjectNames)),
                  weeklyClasses: Value(subject.weeklyClasses),
                  sortOrder: Value(j),
                ),
              );
          subjectCount++;
        }
      }

      var roomCount = 0;
      if (plan.includeDefaultRooms) {
        for (final room in defaultRooms) {
          await db.into(db.rooms).insert(
                RoomsCompanion.insert(
                  name: room.name,
                  deviceId: deviceId,
                  capacity: Value(room.capacity),
                ),
              );
          roomCount++;
        }
      }

      var slotCount = 0;
      if (plan.includeDefaultTimeSlots) {
        for (var i = 0; i < defaultTimeSlots.length; i++) {
          final slot = defaultTimeSlots[i];
          await db.into(db.timeSlots).insert(
                TimeSlotsCompanion.insert(
                  startMinute: slot.start,
                  endMinute: slot.end,
                  deviceId: deviceId,
                  label: Value(slot.label),
                  sortOrder: Value(i),
                ),
              );
          slotCount++;
        }
      }

      await db.recordChange(
        entity: 'institutions',
        entityId: institution.id,
        op: ChangeOp.insert,
        deviceId: deviceId,
        action: 'setup_completed',
        after: {
          'name': plan.centreName,
          'session': plan.sessionName,
          'classes': plan.selectedClasses.length,
          'subjects': subjectCount,
        },
      );

      return SetupResult(
        classes: plan.selectedClasses.length,
        subjects: subjectCount,
        rooms: roomCount,
        timeSlots: slotCount,
      );
    });
  }

  /// Whether setup has already run. Drives whether the app opens the wizard or
  /// the dashboard.
  Future<bool> isComplete(AppDatabase db) async {
    final rows = await db.select(db.institutions).get();
    return rows.any((row) => row.deletedAt == null);
  }
}
