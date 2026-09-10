import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';

/// Raised when something tries to write into a closed month.
class PeriodLockedException implements Exception {
  const PeriodLockedException(this.periodKey);
  final String periodKey;

  @override
  String toString() =>
      'PeriodLockedException: $periodKey is closed. Reopen it before recording '
      'anything dated in that month.';
}

/// Closing the books on a month.
///
/// Once a month is locked nothing dated inside it can be written. This is the
/// thing that stops a figure the owner has already reported — to a partner, an
/// accountant, or simply out loud — from quietly changing afterwards. Locks can
/// be lifted, but lifting one is itself recorded.
class PeriodLockService {
  const PeriodLockService({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  static String keyFor(DateTime when) =>
      '${when.year}-${when.month.toString().padLeft(2, '0')}';

  Future<bool> isLocked(DateTime when) async {
    final row = await (db.select(db.periodLocks)
          ..where((t) =>
              t.periodKey.equals(keyFor(when)) & t.deletedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  /// Throws if [when] falls inside a closed month.
  ///
  /// Called by every service that writes money, so the rule lives in one place
  /// rather than being remembered at each call site.
  Future<void> assertOpen(DateTime when) async {
    if (await isLocked(when)) throw PeriodLockedException(keyFor(when));
  }

  Future<List<PeriodLock>> locked() => (db.select(db.periodLocks)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.desc(t.periodKey)]))
      .get();

  Future<void> lock(DateTime month, {String by = '', String note = ''}) async {
    final key = keyFor(month);
    if (await isLocked(month)) return;

    await db.transaction(() async {
      await db.into(db.periodLocks).insert(
            PeriodLocksCompanion.insert(
              periodKey: key,
              lockedAt: DateTime.now(),
              deviceId: deviceId,
              lockedBy: Value(by),
              note: Value(note),
            ),
          );
      await db.recordChange(
        entity: 'period_locks',
        entityId: key,
        op: ChangeOp.insert,
        deviceId: deviceId,
        action: 'month_closed',
        after: {'period': key, 'by': by},
      );
    });
  }

  /// Reopens a month. Recorded, because reopening a closed book is exactly the
  /// event an audit wants to see.
  Future<void> unlock(PeriodLock row, {required String reason}) async {
    await db.transaction(() async {
      await (db.update(db.periodLocks)..where((t) => t.id.equals(row.id)))
          .write(
        PeriodLocksCompanion(
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await db.recordChange(
        entity: 'period_locks',
        entityId: row.periodKey,
        op: ChangeOp.softDelete,
        deviceId: deviceId,
        action: 'month_reopened',
        before: {'period': row.periodKey},
        after: {'reason': reason},
      );
    });
  }
}
