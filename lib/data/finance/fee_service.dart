import 'package:drift/drift.dart';

import '../../core/app_settings.dart';
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
    this.creditBalance = 0,
  });

  final Student student;
  final List<Invoice> unpaidInvoices;
  final int totalDue;
  final int monthsBehind;

  /// Money already taken and not yet claimed by any invoice. It is spent
  /// automatically on the next charge, so it is shown at the counter rather
  /// than netted silently out of [totalDue].
  final int creditBalance;
}

/// What raising a month's fees actually did.
///
/// "Nothing happened" has two very different causes — everyone was already
/// billed, or nobody has a fee set — and a centre setting up for the first time
/// hits the second one immediately. Reporting only a count made both read as
/// "done".
class BillingResult {
  const BillingResult({
    required this.created,
    required this.alreadyBilled,
    required this.withoutFee,
  });

  final int created;
  final int alreadyBilled;

  /// Students enrolled but skipped because neither they nor their batch has a
  /// monthly fee. Names, so the owner knows exactly whom to fix.
  final List<String> withoutFee;
}

/// What one payment settled.
///
/// Returned rather than left for the caller to re-query, because the receipt
/// has to name the months covered and the front desk has to be told
/// immediately what is still owed.
class CollectionResult {
  const CollectionResult({
    required this.payment,
    required this.settled,
    required this.credited,
    required this.remainingDue,
    this.creditUsed = 0,
  });

  final Payment payment;

  /// Advance already on file that was spent in the same step, before this
  /// payment. Printed on the receipt so the arithmetic on it adds up.
  final int creditUsed;

  /// Period keys this payment cleared or part-cleared, oldest first —
  /// `['2026-07', '2026-08']`.
  final List<String> settled;

  /// Taka left over after every outstanding invoice was covered.
  final int credited;

  /// What the student still owes once this payment is applied.
  final int remainingDue;
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
    int? dueDay,
  }) async =>
      (await raiseMonthlyFees(
        sessionId: sessionId,
        forMonth: forMonth,
        dueDay: dueDay,
      ))
          .created;

  /// Raises a month's tuition for everyone enrolled, and says what it did.
  Future<BillingResult> raiseMonthlyFees({
    required String sessionId,
    required DateTime forMonth,
    int? dueDay,
  }) async {
    final period = periodKeyFor(forMonth);

    // The centre's own due day, not a built-in one. Clamped to 28 so the day
    // exists in February.
    final settings = AppSettings(db: db, deviceId: deviceId);
    final due = (dueDay ?? await settings.readInt(AppSettings.defaultDueDay))
        .clamp(1, 28);

    return db.transaction(() async {
      final monthlyHead = await (db.select(db.feeHeads)
            ..where((t) => t.kind.equalsValue(FeeKind.monthly))
            ..limit(1))
          .getSingleOrNull();
      if (monthlyHead == null) {
        return const BillingResult(
            created: 0, alreadyBilled: 0, withoutFee: []);
      }

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
      var alreadyBilled = 0;
      final withoutFee = <String>[];
      for (final row in rows) {
        final enrollment = row.readTable(db.enrollments);
        final batch = row.readTable(db.batches);
        final student = row.readTable(db.students);
        if (billed.contains(enrollment.studentId)) {
          alreadyBilled++;
          continue;
        }

        // The student's own fee is the real one; the batch fee is only the
        // starting point the desk was offered when they were admitted.
        final gross =
            student.monthlyFee > 0 ? student.monthlyFee : batch.monthlyFee;
        if (gross <= 0) {
          withoutFee.add(student.name);
          continue;
        }

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
                dueOn: Value(DateTime(forMonth.year, forMonth.month, due)),
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

        // An advance the guardian already paid is spent here, the moment
        // there is something to spend it on — the receipt told them it would
        // be.
        await _applyCredit(enrollment.studentId);
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
      return BillingResult(
        created: created,
        alreadyBilled: alreadyBilled,
        withoutFee: withoutFee,
      );
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
  Future<CollectionResult> collect({
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

      // Spread the money across what is actually owed, oldest month first.
      // `invoiceId`, when given, is only a hint about where to start.
      final allocated = await _allocate(
        payment: payment,
        studentId: studentId,
        preferInvoiceId: invoiceId,
      );

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
          'settled': allocated.settled,
          'credited': allocated.credited,
        },
      );

      return allocated;
    });
  }

  /// Applies one payment to a student's outstanding invoices, oldest first.
  ///
  /// The waterfall is the whole point: a guardian paying three months at once
  /// expects three months cleared, and the previous behaviour — attaching the
  /// entire amount to the single oldest invoice — left the other two showing
  /// as unpaid while that one showed as overpaid. Anything left when every
  /// invoice is covered becomes a credit rather than inflating the last one.
  Future<CollectionResult> _allocate({
    required Payment payment,
    required String studentId,
    String? preferInvoiceId,
  }) async {
    // Credit already held is older money than this payment, so it settles
    // first. Otherwise a guardian with an advance on file who pays again
    // would have the new money cover a month the advance should have.
    final creditBefore = await creditBalanceFor(studentId);
    await _applyCredit(studentId);
    final creditUsed = creditBefore - await creditBalanceFor(studentId);

    final outstanding = await (db.select(db.invoices)
          ..where((t) =>
              t.studentId.equals(studentId) &
              t.deletedAt.isNull() &
              t.status.equalsValue(InvoiceStatus.paid).not() &
              t.status.equalsValue(InvoiceStatus.waived).not())
          ..orderBy([(t) => OrderingTerm.asc(t.periodKey)]))
        .get();

    // A caller that named an invoice wants that one settled first; everything
    // else still follows in period order behind it.
    if (preferInvoiceId != null) {
      final index = outstanding.indexWhere((i) => i.id == preferInvoiceId);
      if (index > 0) {
        final preferred = outstanding.removeAt(index);
        outstanding.insert(0, preferred);
      }
    }

    var left = payment.amount;
    final settled = <String>[];
    final touched = <String>[];

    for (final invoice in outstanding) {
      if (left <= 0) break;
      final owed = invoice.netAmount - invoice.paidAmount;
      if (owed <= 0) continue;

      final take = left < owed ? left : owed;
      await db.into(db.paymentAllocations).insert(
            PaymentAllocationsCompanion.insert(
              paymentId: payment.id,
              invoiceId: invoice.id,
              amount: take,
              deviceId: deviceId,
            ),
          );
      left -= take;
      settled.add(invoice.periodKey);
      touched.add(invoice.id);
    }

    for (final id in touched) {
      await _refreshInvoice(id);
    }

    if (left > 0) {
      await db.into(db.studentCredits).insert(
            StudentCreditsCompanion.insert(
              studentId: studentId,
              amount: left,
              deviceId: deviceId,
              paymentId: Value(payment.id),
              reason: const Value('Paid more than was owed'),
            ),
          );
    }

    final remaining = await _outstandingFor(studentId);

    // The payment row carries a short summary of what it paid for, so the
    // record reads correctly on its own — in an export, or to anyone who
    // looks at the row without joining through the allocations. Written in
    // the same transaction that created the row, before anything can read it.
    settled.sort();
    final summary = settled.isEmpty
        ? 'Advance'
        : settled.length == 1
            ? settled.single
            : '${settled.first} to ${settled.last}';
    await (db.update(db.payments)..where((t) => t.id.equals(payment.id)))
        .write(PaymentsCompanion(forPeriod: Value(summary)));

    return CollectionResult(
      payment: payment.copyWith(forPeriod: summary),
      settled: settled,
      credited: left,
      remainingDue: remaining,
      creditUsed: creditUsed,
    );
  }

  /// Spends a student's held credit on their outstanding invoices.
  ///
  /// Credit is always spent in the name of the payment that created it, so an
  /// allocation made from credit points at a real receipt. That is what makes
  /// voiding work: cancel the payment and every invoice its money reached —
  /// directly or as credit — goes back to owing.
  Future<void> _applyCredit(String studentId) async {
    final rows = await (db.select(db.studentCredits)
          ..where((t) =>
              t.studentId.equals(studentId) &
              t.deletedAt.isNull() &
              t.paymentId.isNotNull())
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    if (rows.isEmpty) return;

    // Net per source payment, oldest first.
    final available = <String, int>{};
    for (final row in rows) {
      available.update(row.paymentId!, (v) => v + row.amount,
          ifAbsent: () => row.amount);
    }
    available.removeWhere((_, amount) => amount <= 0);
    if (available.isEmpty) return;

    final outstanding = await (db.select(db.invoices)
          ..where((t) =>
              t.studentId.equals(studentId) &
              t.deletedAt.isNull() &
              t.status.equalsValue(InvoiceStatus.paid).not() &
              t.status.equalsValue(InvoiceStatus.waived).not())
          ..orderBy([(t) => OrderingTerm.asc(t.periodKey)]))
        .get();

    final owed = {for (final i in outstanding) i.id: i.netAmount - i.paidAmount};
    final touched = <String>{};

    for (final source in available.entries) {
      var left = source.value;
      for (final invoice in outstanding) {
        if (left <= 0) break;
        final room = owed[invoice.id]!;
        if (room <= 0) continue;

        final take = left < room ? left : room;
        await db.into(db.paymentAllocations).insert(
              PaymentAllocationsCompanion.insert(
                paymentId: source.key,
                invoiceId: invoice.id,
                amount: take,
                deviceId: deviceId,
                fromCredit: const Value(true),
              ),
            );
        await db.into(db.studentCredits).insert(
              StudentCreditsCompanion.insert(
                studentId: studentId,
                amount: -take,
                deviceId: deviceId,
                paymentId: Value(source.key),
                reason: Value('Used against ${invoice.periodKey}'),
              ),
            );
        owed[invoice.id] = room - take;
        left -= take;
        touched.add(invoice.id);
      }
    }

    for (final id in touched) {
      await _refreshInvoice(id);
    }
  }

  /// Credit a student holds right now.
  Future<int> creditBalanceFor(String studentId) async {
    final rows = await (db.select(db.studentCredits)
          ..where((t) => t.studentId.equals(studentId) & t.deletedAt.isNull()))
        .get();
    final total = rows.fold<int>(0, (sum, r) => sum + r.amount);
    return total < 0 ? 0 : total;
  }

  /// What a student owes, read inside a transaction without building a
  /// [DueSummary].
  Future<int> _outstandingFor(String studentId) async {
    final invoices = await (db.select(db.invoices)
          ..where((t) =>
              t.studentId.equals(studentId) &
              t.deletedAt.isNull() &
              t.status.equalsValue(InvoiceStatus.paid).not() &
              t.status.equalsValue(InvoiceStatus.waived).not()))
        .get();
    return invoices.fold<int>(
        0, (sum, i) => sum + (i.netAmount - i.paidAmount));
  }

  /// The period keys one payment settled, oldest first.
  ///
  /// Needed whenever a receipt is rebuilt after the fact — a reprint has to
  /// say the same months the original did.
  ///
  /// Only what the money settled on the day, by default — which is what the
  /// original receipt printed. Months it reached later as advance are left
  /// out unless [includeAdvance] asks for them.
  Future<List<String>> periodsSettledBy(
    String paymentId, {
    bool includeAdvance = false,
  }) async {
    final rows = await (db.select(db.paymentAllocations).join([
      innerJoin(
        db.invoices,
        db.invoices.id.equalsExp(db.paymentAllocations.invoiceId),
      ),
    ])
          ..where(db.paymentAllocations.paymentId.equals(paymentId) &
              db.paymentAllocations.deletedAt.isNull() &
              (includeAdvance
                  ? const Constant(true)
                  : db.paymentAllocations.fromCredit.equals(false)))
          ..orderBy([OrderingTerm.asc(db.invoices.periodKey)]))
        .get();

    return [for (final r in rows) r.readTable(db.invoices).periodKey];
  }

  /// How much of a payment was held as advance when it was taken.
  Future<int> advanceCreatedBy(String paymentId) async {
    final rows = await (db.select(db.studentCredits)
          ..where((t) =>
              t.paymentId.equals(paymentId) &
              t.deletedAt.isNull() &
              t.amount.isBiggerThanValue(0)))
        .get();
    return rows.fold<int>(0, (sum, r) => sum + r.amount);
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

      // Every invoice this payment touched has to be recomputed, not just
      // the one named on the row. The allocations stay — they are the record
      // of what the money did before it was voided — and `_refreshInvoice`
      // ignores them because the payment is now cancelled.
      final allocations = await (db.select(db.paymentAllocations)
            ..where((t) =>
                t.paymentId.equals(payment.id) & t.deletedAt.isNull()))
          .get();

      final invoiceIds = {
        for (final a in allocations) a.invoiceId,
        if (payment.invoiceId != null) payment.invoiceId!,
      };
      for (final id in invoiceIds) {
        await _refreshInvoice(id);
      }

      // A credit created by an overpayment dies with the payment.
      final credits = await (db.select(db.studentCredits)
            ..where((t) =>
                t.paymentId.equals(payment.id) & t.deletedAt.isNull()))
          .get();
      for (final credit in credits) {
        await (db.update(db.studentCredits)
              ..where((t) => t.id.equals(credit.id)))
            .write(
          StudentCreditsCompanion(
            deletedAt: Value(DateTime.now()),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }

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

    // Summed from allocations, not from payments: one payment may settle
    // several invoices, so "every payment pointing at this invoice" would
    // count money that went to other months.
    final rows = await (db.select(db.paymentAllocations).join([
      innerJoin(
        db.payments,
        db.payments.id.equalsExp(db.paymentAllocations.paymentId),
      ),
    ])
          ..where(db.paymentAllocations.invoiceId.equals(invoiceId) &
              db.paymentAllocations.deletedAt.isNull() &
              db.payments.isCancelled.equals(false) &
              db.payments.deletedAt.isNull()))
        .get();

    final paid = rows.fold<int>(
        0, (sum, r) => sum + r.readTable(db.paymentAllocations).amount);
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
    // `ReceiptSeries` is keyed by prefix so a centre can run more than one
    // book. Reading "the first row" worked only while there was exactly one,
    // and would have silently handed out numbers from the wrong series the
    // moment a second appeared.
    final prefix = await _receiptPrefix();
    final existing = await (db.select(db.receiptSeries)
          ..where((t) => t.prefix.equals(prefix))
          ..limit(1))
        .getSingleOrNull();

    final series = existing ??
        await db.into(db.receiptSeries).insertReturning(
          ReceiptSeriesCompanion.insert(prefix: prefix, deviceId: deviceId),
        );

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

  /// The prefix the centre has configured, falling back to whatever series
  /// already exists so an upgrade keeps numbering where it left off.
  Future<String> _receiptPrefix() async {
    final setting = await (db.select(db.settings)
          ..where((t) =>
              t.key.equals(AppSettings.receiptPrefix) & t.deletedAt.isNull()))
        .getSingleOrNull();
    if (setting != null && setting.value.trim().isNotEmpty) {
      return setting.value.trim();
    }

    final existing = await (db.select(db.receiptSeries)..limit(1))
        .getSingleOrNull();
    return existing?.prefix ?? 'R';
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
      creditBalance: await creditBalanceFor(student.id),
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
