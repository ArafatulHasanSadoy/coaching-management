import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';

/// What one teacher earned in a month.
class PayslipLine {
  const PayslipLine({
    required this.staff,
    required this.periodKey,
    required this.classesTaught,
    required this.gross,
    required this.alreadyPaid,
    this.extraMinutes = 0,
    this.classPay = 0,
    this.hourlyPay = 0,
  });

  final StaffMember staff;
  final String periodKey;

  /// Routine classes taken. Zero for a monthly salary.
  final int classesTaught;

  /// Minutes of extra sittings, paid by the hour.
  final int extraMinutes;

  final int classPay;
  final int hourlyPay;
  final int gross;
  final int alreadyPaid;

  int get outstanding => gross - alreadyPaid;
}

/// Works out what teachers are owed.
///
/// Per-class pay is computed from the class-taken register rather than typed in,
/// which is the whole reason `ClassSessions` records who taught. A teacher paid
/// per class and a register nobody reconciles against is how disputes start.
class PayrollService {
  const PayrollService({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  static String periodKeyFor(DateTime when) =>
      '${when.year}-${when.month.toString().padLeft(2, '0')}';

  /// What a teacher taught in a month, split by how it is paid.
  Future<({int regular, int extraMinutes})> taughtIn({
    required String staffId,
    required DateTime month,
  }) async {
    final from = DateTime(month.year, month.month);
    final to = DateTime(month.year, month.month + 1);

    final rows = await (db.select(db.classSessions)
          ..where((t) =>
              t.staffId.equals(staffId) &
              t.heldOn.isBiggerOrEqualValue(from) &
              t.heldOn.isSmallerThanValue(to) &
              t.state.equalsValue(SessionState.held) &
              t.deletedAt.isNull()))
        .get();

    return (
      regular: rows.where((r) => r.kind == SessionKind.regular).length,
      extraMinutes: rows
          .where((r) => r.kind == SessionKind.extra)
          .fold(0, (sum, r) => sum + r.durationMinutes),
    );
  }

  /// How many classes a teacher took, of both kinds.
  Future<int> classesTaught({
    required String staffId,
    required DateTime month,
  }) async {
    final from = DateTime(month.year, month.month);
    final to = DateTime(month.year, month.month + 1);

    final rows = await (db.select(db.classSessions)
          ..where((t) =>
              t.staffId.equals(staffId) &
              t.heldOn.isBiggerOrEqualValue(from) &
              t.heldOn.isSmallerThanValue(to) &
              t.state.equalsValue(SessionState.held) &
              t.deletedAt.isNull()))
        .get();
    return rows.length;
  }

  /// The payroll for one month, for everyone still on staff.
  Future<List<PayslipLine>> payrollFor(DateTime month) async {
    final period = periodKeyFor(month);
    final people = await (db.select(db.staff)
          ..where((t) => t.deletedAt.isNull() & t.isActive.equals(true))
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();

    final paid = await (db.select(db.salaryPayments)
          ..where((t) =>
              t.periodKey.equals(period) &
              t.isCancelled.equals(false) &
              t.deletedAt.isNull()))
        .get();

    final lines = <PayslipLine>[];
    for (final person in people) {
      if (person.payModel == PayModel.monthly) {
        lines.add(
          PayslipLine(
            staff: person,
            periodKey: period,
            classesTaught: 0,
            extraMinutes: 0,
            classPay: 0,
            hourlyPay: 0,
            gross: person.monthlySalary,
            alreadyPaid: _paidTo(paid, person.id),
          ),
        );
        continue;
      }

      // Routine classes pay the per-class rate; extra sittings pay by the hour.
      // A teacher on both rates therefore earns two lines that add up, rather
      // than the app having to choose one model for them.
      final taught = await taughtIn(staffId: person.id, month: month);
      final classPay = taught.regular * person.perClassRate;
      final hourlyPay =
          (taught.extraMinutes * person.hourlyRate / 60).round();

      lines.add(
        PayslipLine(
          staff: person,
          periodKey: period,
          classesTaught: taught.regular,
          extraMinutes: taught.extraMinutes,
          classPay: classPay,
          hourlyPay: hourlyPay,
          gross: classPay + hourlyPay,
          alreadyPaid: _paidTo(paid, person.id),
        ),
      );
    }
    return lines;
  }

  static int _paidTo(List<SalaryPayment> paid, String staffId) => paid
      .where((p) => p.staffId == staffId)
      .fold(0, (sum, p) => sum + p.netAmount);
}
