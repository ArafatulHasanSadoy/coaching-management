import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';
import 'ledger_service.dart';
import 'period_lock_service.dart';

/// Money going out, and the end-of-day count.
class ExpenseService {
  const ExpenseService({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  LedgerService get _ledger => LedgerService(db: db, deviceId: deviceId);
  PeriodLockService get _locks =>
      PeriodLockService(db: db, deviceId: deviceId);

  Future<Expense> record({
    required String headId,
    required String accountId,
    required int amount,
    DateTime? spentOn,
    String paidTo = '',
    String reference = '',
    String note = '',
    String customHead = '',
  }) async {
    if (amount <= 0) {
      throw ArgumentError.value(amount, 'amount', 'must be more than zero');
    }
    final when = spentOn ?? DateTime.now();
    await _locks.assertOpen(when);

    return db.transaction(() async {
      final expense = await db.into(db.expenses).insertReturning(
            ExpensesCompanion.insert(
              headId: headId,
              accountId: accountId,
              amount: amount,
              spentOn: when,
              deviceId: deviceId,
              paidTo: Value(paidTo),
              reference: Value(reference),
              customHead: Value(customHead.trim()),
              note: Value(note),
            ),
          );

      await _ledger.post(
        accountId: accountId,
        // Negative: an expense leaves the account.
        amount: -amount,
        kind: LedgerKind.expense,
        occurredOn: when,
        description: paidTo.isEmpty ? 'Expense' : 'Expense — $paidTo',
        sourceEntity: 'expenses',
        sourceId: expense.id,
      );

      await db.recordChange(
        entity: 'expenses',
        entityId: expense.id,
        op: ChangeOp.insert,
        deviceId: deviceId,
        action: 'recorded',
        after: {
          'amount': amount,
          'paidTo': paidTo,
          if (customHead.trim().isNotEmpty) 'customHead': customHead.trim(),
        },
      );

      return expense;
    });
  }

  Future<void> cancel(Expense expense, {required String reason}) async {
    if (expense.isCancelled) return;
    await _locks.assertOpen(expense.spentOn);
    await db.transaction(() async {
      await (db.update(db.expenses)..where((t) => t.id.equals(expense.id)))
          .write(
        ExpensesCompanion(
          isCancelled: const Value(true),
          note: Value('${expense.note} [cancelled: $reason]'.trim()),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await _ledger.reverseSource(
        sourceEntity: 'expenses',
        sourceId: expense.id,
        reason: reason,
      );
      await db.recordChange(
        entity: 'expenses',
        entityId: expense.id,
        op: ChangeOp.update,
        deviceId: deviceId,
        action: 'cancelled',
        before: {'amount': expense.amount},
        after: {'reason': reason},
      );
    });
  }

  Future<SalaryPayment> paySalary({
    required String staffId,
    required String accountId,
    required String periodKey,
    required int grossAmount,
    int deductions = 0,
    DateTime? paidOn,
    String note = '',
  }) async {
    final when = paidOn ?? DateTime.now();
    await _locks.assertOpen(when);
    final net = grossAmount - deductions;

    return db.transaction(() async {
      final row = await db.into(db.salaryPayments).insertReturning(
            SalaryPaymentsCompanion.insert(
              staffId: staffId,
              accountId: accountId,
              periodKey: periodKey,
              grossAmount: grossAmount,
              netAmount: net,
              paidOn: when,
              deviceId: deviceId,
              deductions: Value(deductions),
              note: Value(note),
            ),
          );

      await _ledger.post(
        accountId: accountId,
        amount: -net,
        kind: LedgerKind.expense,
        occurredOn: when,
        description: 'Salary — $periodKey',
        sourceEntity: 'salary_payments',
        sourceId: row.id,
      );

      await db.recordChange(
        entity: 'salary_payments',
        entityId: row.id,
        op: ChangeOp.insert,
        deviceId: deviceId,
        action: 'paid',
        after: {'staffId': staffId, 'net': net, 'period': periodKey},
      );

      return row;
    });
  }

  /// Records a physical cash count against what the ledger says.
  ///
  /// The difference is stored rather than derived, so a later correction
  /// elsewhere cannot quietly rewrite what was counted on the night.
  Future<DailyClosing> closeDay({
    required String accountId,
    required int countedAmount,
    DateTime? forDay,
    String note = '',
    String closedBy = '',
  }) async {
    final day = forDay ?? DateTime.now();

    // Every other money write checks this; a day closing is a money record
    // like any other, and closing a day inside a month the owner has already
    // reported would change figures they have handed out.
    await _locks.assertOpen(day);

    final expected = await _ledger.balanceOf(accountId);

    final closing = await db.into(db.dailyClosings).insertReturning(
          DailyClosingsCompanion.insert(
            closedFor: DateTime(day.year, day.month, day.day),
            accountId: accountId,
            expectedAmount: expected,
            countedAmount: countedAmount,
            difference: countedAmount - expected,
            deviceId: deviceId,
            note: Value(note),
            closedBy: Value(closedBy),
          ),
        );

    await db.recordChange(
      entity: 'daily_closings',
      entityId: closing.id,
      op: ChangeOp.insert,
      deviceId: deviceId,
      action: 'day_closed',
      after: {
        'expected': expected,
        'counted': countedAmount,
        'difference': countedAmount - expected,
      },
    );

    return closing;
  }

  /// Expenses in a date range, newest first. Cancelled ones stay listed.
  Future<List<Expense>> between(DateTime from, DateTime to) =>
      (db.select(db.expenses)
            ..where((t) =>
                t.spentOn.isBiggerOrEqualValue(from) &
                t.spentOn.isSmallerThanValue(to) &
                t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.spentOn)]))
          .get();
}
