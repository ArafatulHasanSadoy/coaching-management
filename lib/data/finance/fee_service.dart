import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';
import 'ledger_service.dart';
import 'period_lock_service.dart';

/// What a student currently owes.
class DueSummary {
  const DueSummary({
    required this.student,
    required this.unpaidInvoices,
    required this.totalDue,
    required this.monthsBehind,
  });

  final Student student;
  final List<Invoice> unpaidInvoices;
  final int totalDue;
  final int monthsBehind;
}

/// Raising charges and taking money.
///
/// Three rules hold everywhere in here, because a fee system that cannot be
/// audited is worse than a paper receipt book:
///
///  * **Receipt numbers are gapless.** A missing number is the first thing an
///    auditor asks about, so numbers are allocated inside the same transaction
///    as the payment and are never reused — a cancelled receipt keeps its
///    number and is marked cancelled.
///  * **Payments are immutable.** Cancelling writes a compensating ledger entry
///    and flags the row. Nothing is deleted or edited.
///  * **Invoice totals are recomputed from live payments**, never incremented,
///    so a cancellation cannot leave a stale figure behind.
class FeeService {
  const FeeService({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  LedgerService get _ledger => LedgerService(db: db, deviceId: deviceId);
  PeriodLockService get _locks =>
      PeriodLockService(db: db, deviceId: deviceId);

  /// The period key for a month: `2026-03`.
  static String periodKeyFor(DateTime when) =>
      '${when.year}-${when.month.toString().padLeft(2, '0')}';

  /// Creates the fee heads, accounts and expense heads a centre needs on day
  /// one, if they are not there already. Safe to call repeatedly.
  Future<void> ensureDefaults() async {
    final existingHeads = await db.select(db.feeHeads).get();
    if (existingHeads.isEmpty) {
      const heads = [
        ('Monthly tuition', FeeKind.monthly),
        ('Admission fee', FeeKind.admission),
        ('Exam fee', FeeKind.exam),
        ('Books and sheets', FeeKind.material),
      ];
      for (var i = 0; i < heads.length; i++) {
        await db.into(db.feeHeads).insert(
              FeeHeadsCompanion.insert(
                name: heads[i].$1,
                kind: heads[i].$2,
                deviceId: deviceId,
                sortOrder: Value(i),
              ),
            );
      }
    }

    final existingAccounts = await db.select(db.accounts).get();
    if (existingAccounts.isEmpty) {
      const wallets = [
        ('Cash', AccountKind.cash),
        ('bKash', AccountKind.bkash),
        ('Nagad', AccountKind.nagad),
        ('Bank', AccountKind.bank),
      ];
      for (var i = 0; i < wallets.length; i++) {
        await db.into(db.accounts).insert(
              AccountsCompanion.insert(
                name: wallets[i].$1,
                kind: wallets[i].$2,
                deviceId: deviceId,
                sortOrder: Value(i),
              ),
            );
      }
    }

    final existingExpenseHeads = await db.select(db.expenseHeads).get();
    if (existingExpenseHeads.isEmpty) {
      const names = [
        'Rent', 'Teacher salary', 'Staff salary', 'Electricity', 'Internet',
        'Printing and stationery', 'Marketing', 'Maintenance', 'Transport',
        'Other',
      ];
      for (var i = 0; i < names.length; i++) {
        await db.into(db.expenseHeads).insert(
              ExpenseHeadsCompanion.insert(
                name: names[i],
                deviceId: deviceId,
                sortOrder: Value(i),
              ),
            );
      }
    }

    final series = await db.select(db.receiptSeries).get();
    if (series.isEmpty) {
      await db.into(db.receiptSeries).insert(
            ReceiptSeriesCompanion.insert(prefix: 'R', deviceId: deviceId),
          );
    }
  }

  /// Raises monthly tuition for everyone enrolled in [sessionId].
  ///
  /// Idempotent per period: a student already billed for that month is skipped,
  /// so running it twice cannot double-charge a centre's students.
  Future<int> generateMonthlyInvoices({
    required String sessionId,
    required DateTime forMonth,
    int dueDay = 10,
  }) async {
    final period = periodKeyFor(forMonth);

    return db.transaction(() async {
      final monthlyHead = await (db.select(db.feeHeads)
            ..where((t) => t.kind.equalsValue(FeeKind.monthly))
            ..limit(1))
          .getSingleOrNull();
      if (monthlyHead == null) return 0;

      final rows = await (db.select(db.enrollments).join([
        innerJoin(db.batches, db.batches.id.equalsExp(db.enrollments.batchId)),
        innerJoin(db.students, db.students.id.equalsExp(db.enrollments.studentId)),
      ])
            ..where(db.enrollments.sessionId.equals(sessionId) &
                db.enrollments.isActive.equals(true) &
                db.enrollments.deletedAt.isNull() &
                db.students.deletedAt.isNull()))
          .get();

      final already = await (db.select(db.invoices)
            ..where((t) =>
                t.periodKey.equals(period) & t.deletedAt.isNull()))
          .get();
      final billed = {for (final i in already) i.studentId};

      var created = 0;
      for (final row in rows) {
        final enrollment = row.readTable(db.enrollments);
        final batch = row.readTable(db.batches);
        final student = row.readTable(db.students);
        if (billed.contains(enrollment.studentId)) continue;

        // The student's own fee is the real one; the batch fee is only the
        // starting point the desk was offered when they were admitted.
        final gross =
            student.monthlyFee > 0 ? student.monthlyFee : batch.monthlyFee;
        if (gross <= 0) continue;

        final discount = await _discountFor(
          studentId: enrollment.studentId,
          feeHeadId: monthlyHead.id,
          on: forMonth,
        );
        final applied = discount > gross ? gross : discount;

        final invoice = await db.into(db.invoices).insertReturning(
              InvoicesCompanion.insert(
                studentId: enrollment.studentId,
                sessionId: sessionId,
                periodKey: period,
                issuedOn: forMonth,
                status: InvoiceStatus.unpaid,
                deviceId: deviceId,
                batchId: Value(batch.id),
                dueOn: Value(DateTime(forMonth.year, forMonth.month, dueDay)),
                grossAmount: Value(gross),
                discountAmount: Value(applied),
                netAmount: Value(gross - applied),
              ),
            );

        await db.into(db.invoiceItems).insert(
              InvoiceItemsCompanion.insert(
                invoiceId: invoice.id,
                feeHeadId: monthlyHead.id,
                label: '${monthlyHead.name} — $period',
                amount: gross,
                deviceId: deviceId,
                discount: Value(applied),
              ),
            );
        created++;
      }

      if (created > 0) {
        await db.recordChange(
          entity: 'invoices',
          entityId: 'generate:$period',
          op: ChangeOp.insert,
          deviceId: deviceId,
          action: 'invoices_generated',
          after: {'period': period, 'count': created},
        );
      }
      return created;
    });
  }

  Future<int> _discountFor({
    required String studentId,
    required String feeHeadId,
    required DateTime on,
  }) async {
    final rows = await (db.select(db.discounts)
          ..where((t) => t.studentId.equals(studentId) & t.deletedAt.isNull()))
        .get();
    var total = 0;
    for (final d in rows) {
      if (d.feeHeadId != null && d.feeHeadId != feeHeadId) continue;
      if (d.validFrom != null && on.isBefore(d.validFrom!)) continue;
      if (d.validTo != null && on.isAfter(d.validTo!)) continue;
      total += d.amount;
    }
    return total;
  }

  /// Takes a payment and returns the receipt.
  ///
  /// Everything — the receipt number, the payment row, the invoice totals and
  /// the ledger entry — happens in one transaction. A payment that updated the
  /// student's balance but never reached the ledger, or vice versa, is exactly
  /// the kind of drift that makes a centre stop trusting the app.
  Future<Payment> collect({
    required String studentId,
    required int amount,
    required PaymentMethod method,
    required String accountId,
    String? invoiceId,
    DateTime? receivedOn,
    String receivedBy = '',
    String reference = '',
    String forPeriod = '',
    String note = '',
  }) async {
    if (amount <= 0) {
      throw ArgumentError.value(amount, 'amount', 'must be more than zero');
    }
    final when = receivedOn ?? DateTime.now();

    // Checked before the transaction opens: a closed month means the owner has
    // already reported those figures, and a late payment dated into it would
    // silently change what they said.
    await _locks.assertOpen(when);

    return db.transaction(() async {
      final receiptNo = await _allocateReceiptNumber();

      final payment = await db.into(db.payments).insertReturning(
            PaymentsCompanion.insert(
              receiptNo: receiptNo,
              studentId: studentId,
              amount: amount,
              method: method,
              accountId: accountId,
              receivedOn: when,
              deviceId: deviceId,
              invoiceId: Value(invoiceId),
              reference: Value(reference),
              receivedBy: Value(receivedBy),
              forPeriod: Value(forPeriod),
              note: Value(note),
            ),
          );

      await _ledger.post(
        accountId: accountId,
        amount: amount,
        kind: LedgerKind.income,
        occurredOn: when,
        description: 'Fee — receipt $receiptNo',
        sourceEntity: 'payments',
        sourceId: payment.id,
      );

      if (invoiceId != null) await _refreshInvoice(invoiceId);

      await db.recordChange(
        entity: 'payments',
        entityId: payment.id,
        op: ChangeOp.insert,
        deviceId: deviceId,
        action: 'collected',
        after: {
          'receiptNo': receiptNo,
          'amount': amount,
          'method': method.name,
          'studentId': studentId,
        },
      );

      return payment;
    });
  }

  /// Voids a payment. The row stays, the number stays used, the money is undone.
  Future<void> cancelPayment(Payment payment, {required String reason}) async {
    if (payment.isCancelled) return;
    await _locks.assertOpen(payment.receivedOn);

    await db.transaction(() async {
      await (db.update(db.payments)..where((t) => t.id.equals(payment.id)))
          .write(
        PaymentsCompanion(
          isCancelled: const Value(true),
          cancelReason: Value(reason),
          updatedAt: Value(DateTime.now()),
        ),
      );

      await _ledger.reverseSource(
        sourceEntity: 'payments',
        sourceId: payment.id,
        reason: reason,
      );

      if (payment.invoiceId != null) await _refreshInvoice(payment.invoiceId!);

      await db.recordChange(
        entity: 'payments',
        entityId: payment.id,
        op: ChangeOp.update,
        deviceId: deviceId,
        action: 'cancelled',
        before: {'amount': payment.amount, 'receiptNo': payment.receiptNo},
        after: {'isCancelled': true, 'reason': reason},
      );
    });
  }

  /// Recomputes an invoice from the payments that are still live.
  Future<void> _refreshInvoice(String invoiceId) async {
    final invoice = await (db.select(db.invoices)
          ..where((t) => t.id.equals(invoiceId)))
        .getSingleOrNull();
    if (invoice == null) return;

    final payments = await (db.select(db.payments)
          ..where((t) =>
              t.invoiceId.equals(invoiceId) &
              t.isCancelled.equals(false) &
              t.deletedAt.isNull()))
        .get();

    final paid = payments.fold<int>(0, (sum, p) => sum + p.amount);
    final status = paid <= 0
        ? InvoiceStatus.unpaid
        : paid >= invoice.netAmount
            ? InvoiceStatus.paid
            : InvoiceStatus.partial;

    await (db.update(db.invoices)..where((t) => t.id.equals(invoiceId))).write(
      InvoicesCompanion(
        paidAmount: Value(paid),
        status: Value(status),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Reserves the next receipt number.
  ///
  /// Called only inside a transaction, so two payments taken at once cannot be
  /// handed the same number.
  Future<String> _allocateReceiptNumber() async {
    final series = await (db.select(db.receiptSeries)..limit(1)).getSingle();
    final number = series.nextNumber;

    await (db.update(db.receiptSeries)..where((t) => t.id.equals(series.id)))
        .write(
      ReceiptSeriesCompanion(
        nextNumber: Value(number + 1),
        updatedAt: Value(DateTime.now()),
      ),
    );

    return '${series.prefix}-${number.toString().padLeft(series.padding, '0')}';
  }

  // ---- dues ------------------------------------------------------------

  Future<DueSummary> duesFor(Student student) async {
    final invoices = await (db.select(db.invoices)
          ..where((t) =>
              t.studentId.equals(student.id) &
              t.deletedAt.isNull() &
              t.status.equalsValue(InvoiceStatus.paid).not() &
              t.status.equalsValue(InvoiceStatus.waived).not())
          ..orderBy([(t) => OrderingTerm.asc(t.periodKey)]))
        .get();

    final total =
        invoices.fold<int>(0, (sum, i) => sum + (i.netAmount - i.paidAmount));

    return DueSummary(
      student: student,
      unpaidInvoices: invoices,
      totalDue: total,
      monthsBehind: invoices.length,
    );
  }

  /// Everyone who owes something, worst first.
  Future<List<DueSummary>> defaulters({int minMonths = 1}) async {
    final rows = await (db.select(db.invoices).join([
      innerJoin(db.students, db.students.id.equalsExp(db.invoices.studentId)),
    ])
          ..where(db.invoices.deletedAt.isNull() &
              db.invoices.status.equalsValue(InvoiceStatus.paid).not() &
              db.invoices.status.equalsValue(InvoiceStatus.waived).not() &
              db.students.deletedAt.isNull()))
        .get();

    final byStudent = <String, (Student, List<Invoice>)>{};
    for (final row in rows) {
      final student = row.readTable(db.students);
      final invoice = row.readTable(db.invoices);
      byStudent
          .putIfAbsent(student.id, () => (student, <Invoice>[]))
          .$2
          .add(invoice);
    }

    final summaries = <DueSummary>[];
    for (final (student, invoices) in byStudent.values) {
      if (invoices.length < minMonths) continue;
      invoices.sort((a, b) => a.periodKey.compareTo(b.periodKey));
      summaries.add(
        DueSummary(
          student: student,
          unpaidInvoices: invoices,
          totalDue: invoices.fold<int>(
              0, (sum, i) => sum + (i.netAmount - i.paidAmount)),
          monthsBehind: invoices.length,
        ),
      );
    }

    summaries.sort((a, b) => b.totalDue.compareTo(a.totalDue));
    return summaries;
  }

  Future<int> outstandingTotal() async {
    final invoices = await (db.select(db.invoices)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.status.equalsValue(InvoiceStatus.paid).not() &
              t.status.equalsValue(InvoiceStatus.waived).not()))
        .get();
    return invoices.fold<int>(
        0, (sum, i) => sum + (i.netAmount - i.paidAmount));
  }

  Future<List<Payment>> paymentsOn(DateTime day) {
    final from = DateTime(day.year, day.month, day.day);
    final to = from.add(const Duration(days: 1));
    return (db.select(db.payments)
          ..where((t) =>
              t.receivedOn.isBiggerOrEqualValue(from) &
              t.receivedOn.isSmallerThanValue(to) &
              t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.receivedOn)]))
        .get();
  }

  /// Every receipt issued to one student, newest first — including cancelled
  /// ones, which stay visible on purpose.
  Future<List<Payment>> paymentsFor(String studentId) =>
      (db.select(db.payments)
            ..where((t) => t.studentId.equals(studentId) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.receivedOn)]))
          .get();
}
