import 'package:drift/drift.dart';

import '../../core/phone.dart';
import '../db/database.dart';
import '../db/tables.dart';

/// People who asked about the centre but have not joined.
///
/// A centre's growth lives here: a parent who rang in March and was never
/// called back is revenue that walked away, and nobody remembers it without a
/// list. Deliberately separate from students — an enquiry is not an admission,
/// and conflating them inflates the roll.
class EnquiryService {
  const EnquiryService({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  Stream<List<Enquiry>> watchOpen() => (db.select(db.enquiries)
        ..where((t) =>
            t.deletedAt.isNull() &
            t.status.equalsValue(EnquiryStatus.admitted).not() &
            t.status.equalsValue(EnquiryStatus.lost).not())
        ..orderBy([(t) => OrderingTerm.asc(t.followUpOn)]))
      .watch();

  /// Enquiries whose follow-up date has arrived — the call list for today.
  Future<List<Enquiry>> dueForFollowUp({DateTime? on}) async {
    final day = on ?? DateTime.now();
    final end = DateTime(day.year, day.month, day.day)
        .add(const Duration(days: 1));

    return (db.select(db.enquiries)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.followUpOn.isNotNull() &
              t.followUpOn.isSmallerThanValue(end) &
              t.status.equalsValue(EnquiryStatus.admitted).not() &
              t.status.equalsValue(EnquiryStatus.lost).not())
          ..orderBy([(t) => OrderingTerm.asc(t.followUpOn)]))
        .get();
  }

  Future<Enquiry> record({
    required String name,
    String phone = '',
    String? classId,
    String source = '',
    DateTime? followUpOn,
    String note = '',
  }) async {
    final row = await db.into(db.enquiries).insertReturning(
          EnquiriesCompanion.insert(
            name: name.trim(),
            status: EnquiryStatus.open,
            enquiredOn: DateTime.now(),
            deviceId: deviceId,
            phone: Value(phone.trim()),
            phoneNorm: Value(Phone.normalize(phone)),
            classId: Value(classId),
            source: Value(source),
            followUpOn: Value(followUpOn),
            note: Value(note),
          ),
        );

    await db.recordChange(
      entity: 'enquiries',
      entityId: row.id,
      op: ChangeOp.insert,
      deviceId: deviceId,
      action: 'enquiry_recorded',
      after: {'name': name, 'source': source},
    );
    return row;
  }

  Future<void> setStatus(
    Enquiry row,
    EnquiryStatus status, {
    DateTime? followUpOn,
    String note = '',
    String? convertedStudentId,
  }) async {
    await (db.update(db.enquiries)..where((t) => t.id.equals(row.id))).write(
      EnquiriesCompanion(
        status: Value(status),
        followUpOn: Value(followUpOn ?? row.followUpOn),
        note: Value(note.isEmpty ? row.note : note),
        convertedStudentId: Value(convertedStudentId ?? row.convertedStudentId),
        updatedAt: Value(DateTime.now()),
      ),
    );

    await db.recordChange(
      entity: 'enquiries',
      entityId: row.id,
      op: ChangeOp.update,
      deviceId: deviceId,
      action: 'enquiry_${status.name}',
      before: {'status': row.status.name},
      after: {'status': status.name, 'student': convertedStudentId},
    );
  }

  /// How enquiries turned out over a period — the only honest measure of
  /// whether the centre's marketing is working.
  Future<({int total, int admitted, int lost, int open})> funnel({
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await (db.select(db.enquiries)
          ..where((t) =>
              t.enquiredOn.isBiggerOrEqualValue(from) &
              t.enquiredOn.isSmallerThanValue(to) &
              t.deletedAt.isNull()))
        .get();

    return (
      total: rows.length,
      admitted:
          rows.where((r) => r.status == EnquiryStatus.admitted).length,
      lost: rows.where((r) => r.status == EnquiryStatus.lost).length,
      open: rows
          .where((r) =>
              r.status == EnquiryStatus.open ||
              r.status == EnquiryStatus.followUp)
          .length,
    );
  }
}
