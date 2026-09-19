import 'dart:io';

import 'package:coaching_ops/core/permissions.dart';
import 'package:coaching_ops/data/attendance/attendance_service.dart';
import 'package:coaching_ops/data/backup/backup_service.dart';
import 'package:coaching_ops/data/db/database.dart';
import 'package:coaching_ops/data/db/tables.dart';
import 'package:coaching_ops/data/documents/document_engine.dart';
import 'package:coaching_ops/data/documents/receipt_document.dart';
import 'package:coaching_ops/data/finance/expense_service.dart';
import 'package:coaching_ops/data/finance/fee_service.dart';
import 'package:coaching_ops/data/finance/ledger_service.dart';
import 'package:coaching_ops/core/app_settings.dart';
import 'package:coaching_ops/data/finance/period_lock_service.dart';
import 'package:coaching_ops/data/inventory/inventory_service.dart';
import 'package:coaching_ops/data/students/students_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late FeeService fees;
  late LedgerService ledger;
  late ExpenseService expenses;
  late StudentsRepository students;
  late String sessionId;
  late String batchId;
  late String cashId;

  const device = 'device-a';

  setUp(() async {
    db = AppDatabase.memory();
    fees = FeeService(db: db, deviceId: device);
    ledger = LedgerService(db: db, deviceId: device);
    expenses = ExpenseService(db: db, deviceId: device);
    students = StudentsRepository(db: db, deviceId: device);

    final session = await db.into(db.academicSessions).insertReturning(
          AcademicSessionsCompanion.insert(
            name: '2026',
            startDate: DateTime(2026, 1, 1),
            endDate: DateTime(2026, 12, 31),
            deviceId: device,
            isActive: const Value(true),
          ),
        );
    sessionId = session.id;

    final schoolClass = await db.into(db.classes).insertReturning(
          ClassesCompanion.insert(name: 'Class 9', deviceId: device),
        );
    final batch = await db.into(db.batches).insertReturning(
          BatchesCompanion.insert(
            sessionId: sessionId,
            classId: schoolClass.id,
            name: 'Science A',
            status: BatchStatus.active,
            deviceId: device,
            monthlyFee: const Value(2500),
          ),
        );
    batchId = batch.id;

    await fees.ensureDefaults();
    cashId = (await db.select(db.accounts).get())
        .firstWhere((a) => a.kind == AccountKind.cash)
        .id;
  });

  tearDown(() => db.close());

  Future<Student> admit(String name) => students.admit(
        name: name,
        batchId: batchId,
        sessionId: sessionId,
        guardianPhone: '01712345678',
      );

  // ===================== Stage 4 =====================

  group('Stage 4 — roles', () {
    test('the owner can do everything', () {
      for (final c in Capability.values) {
        expect(Permissions.allows(UserRole.owner, c), isTrue, reason: c.name);
      }
    });

    test('staff can run the counter but cannot see the business', () {
      // The gate: a receptionist collects fees and must not see profit.
      expect(Permissions.allows(UserRole.staff, Capability.collectFees), isTrue);
      expect(
          Permissions.allows(UserRole.staff, Capability.manageStudents), isTrue);
      expect(
          Permissions.allows(UserRole.staff, Capability.takeAttendance), isTrue);

      expect(
        Permissions.allows(UserRole.staff, Capability.viewFinanceSummary),
        isFalse,
        reason: 'profit is the owner’s business',
      );
      expect(
        Permissions.allows(UserRole.staff, Capability.viewStaffSalaries),
        isFalse,
        reason: 'what each teacher earns is not counter information',
      );
      expect(Permissions.allows(UserRole.staff, Capability.manageExpenses),
          isFalse);
      expect(
          Permissions.allows(UserRole.staff, Capability.manageBackup), isFalse);
    });
  });

  // ===================== Release 2 — §0.1 =====================

  group('paying several months at once (owner Q189/Q190)', () {
    /// Raises `months` consecutive ৳2500 invoices for one student.
    Future<Student> owing(int months) async {
      final student = await admit('Rahim');
      for (var i = 0; i < months; i++) {
        await fees.generateMonthlyInvoices(
          sessionId: sessionId,
          forMonth: DateTime(2026, 7 + i, 1),
        );
      }
      return student;
    }

    test('one payment for three months clears all three', () async {
      final student = await owing(3);
      expect((await fees.duesFor(student)).totalDue, 7500);

      final result = await fees.collect(
        studentId: student.id,
        amount: 7500,
        method: PaymentMethod.cash,
        accountId: cashId,
      );

      // The bug this replaces: the whole 7500 was attached to July, which
      // then read "paid 7500 of 2500", while August and September stayed
      // unpaid and the student was still shown as two months behind.
      expect(result.settled, ['2026-07', '2026-08', '2026-09']);
      expect(result.remainingDue, 0);
      expect(result.credited, 0);

      final invoices = await db.select(db.invoices).get();
      expect(invoices.every((i) => i.status == InvoiceStatus.paid), isTrue);
      expect(invoices.every((i) => i.paidAmount == i.netAmount), isTrue);
      expect((await fees.duesFor(student)).totalDue, 0);
      expect((await fees.duesFor(student)).monthsBehind, 0);
    });

    test('a part payment fills the oldest months and leaves the rest', () async {
      final student = await owing(3);

      final result = await fees.collect(
        studentId: student.id,
        amount: 4000,
        method: PaymentMethod.cash,
        accountId: cashId,
      );

      // July in full, half of August, September untouched.
      expect(result.settled, ['2026-07', '2026-08']);
      expect(result.remainingDue, 3500);

      final byPeriod = {
        for (final i in await db.select(db.invoices).get()) i.periodKey: i,
      };
      expect(byPeriod['2026-07']!.status, InvoiceStatus.paid);
      expect(byPeriod['2026-08']!.status, InvoiceStatus.partial);
      expect(byPeriod['2026-08']!.paidAmount, 1500);
      expect(byPeriod['2026-09']!.status, InvoiceStatus.unpaid);
      expect(byPeriod['2026-09']!.paidAmount, 0);
    });

    test('no invoice is ever recorded as overpaid', () async {
      final student = await owing(1);

      final result = await fees.collect(
        studentId: student.id,
        amount: 4000,
        method: PaymentMethod.cash,
        accountId: cashId,
      );

      final invoice = (await db.select(db.invoices).get()).single;
      expect(invoice.paidAmount, 2500);
      expect(invoice.paidAmount, lessThanOrEqualTo(invoice.netAmount));

      // The surplus is held, not absorbed.
      expect(result.credited, 1500);
      final credit = (await db.select(db.studentCredits).get()).single;
      expect(credit.amount, 1500);
      expect(credit.studentId, student.id);
    });

    test('the receipt names the months the money cleared', () async {
      final student = await owing(2);
      final result = await fees.collect(
        studentId: student.id,
        amount: 5000,
        method: PaymentMethod.cash,
        accountId: cashId,
      );

      final html = ReceiptDocument(engine: const DocumentEngine()).build(
        payment: result.payment,
        student: student,
        previousDue: 5000,
        settledPeriods: result.settled,
        remainingDue: result.remainingDue,
        credited: result.credited,
      );

      expect(html, contains('July 2026, August 2026'));
      expect(html, contains('Remaining due'));
    });

    test('an advance is spent on the next month, as the receipt promised',
        () async {
      final student = await owing(1); // July, ৳2500
      final result = await fees.collect(
        studentId: student.id,
        amount: 4000,
        method: PaymentMethod.cash,
        accountId: cashId,
      );
      expect(result.credited, 1500);
      expect((await fees.duesFor(student)).creditBalance, 1500);

      // August arrives. The ৳1500 the receipt said was "kept as advance" has
      // to come off it — otherwise the guardian is billed for money already
      // in the drawer.
      await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 8, 1),
      );

      final due = await fees.duesFor(student);
      expect(due.totalDue, 1000);
      expect(due.creditBalance, 0);

      final august = (await db.select(db.invoices).get())
          .firstWhere((i) => i.periodKey == '2026-08');
      expect(august.paidAmount, 1500);
      expect(august.status, InvoiceStatus.partial);
    });

    test('money paid before any invoice exists waits for one', () async {
      final student = await admit('Rahim');

      final result = await fees.collect(
        studentId: student.id,
        amount: 5000,
        method: PaymentMethod.cash,
        accountId: cashId,
      );
      expect(result.settled, isEmpty);
      expect(result.credited, 5000);

      await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 7, 1),
      );
      await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 8, 1),
      );

      expect((await fees.duesFor(student)).totalDue, 0);
      expect((await fees.duesFor(student)).creditBalance, 0);
    });

    test('credit already held is used before new money', () async {
      final student = await owing(1);
      await fees.collect(
        studentId: student.id,
        amount: 3000, // ৳500 over
        method: PaymentMethod.cash,
        accountId: cashId,
      );

      // A charge raised by some other route, with the credit still sitting
      // unspent — then the guardian pays again.
      await db.into(db.invoices).insert(
            InvoicesCompanion.insert(
              studentId: student.id,
              sessionId: sessionId,
              periodKey: '2026-08',
              issuedOn: DateTime(2026, 8, 1),
              status: InvoiceStatus.unpaid,
              deviceId: device,
              grossAmount: const Value(2500),
              netAmount: const Value(2500),
            ),
          );

      final result = await fees.collect(
        studentId: student.id,
        amount: 2000,
        method: PaymentMethod.cash,
        accountId: cashId,
      );

      // ৳500 credit + ৳2000 new = ৳2500: August is settled, nothing held.
      expect(result.remainingDue, 0);
      expect(result.credited, 0);
      expect(result.creditUsed, 500);
      expect((await fees.duesFor(student)).creditBalance, 0);

      // And the receipt shows where the other ৳500 came from, so
      // "previous due 2500, paid 2000, remaining 0" adds up on paper.
      final html = ReceiptDocument(engine: const DocumentEngine()).build(
        payment: result.payment,
        student: student,
        previousDue: 2500,
        settledPeriods: result.settled,
        remainingDue: result.remainingDue,
        creditUsed: result.creditUsed,
      );
      expect(html, contains('Advance used'));
      expect(html, contains('৳ 500'));
    });

    test('voiding the payment that made a credit undoes what it paid for',
        () async {
      final student = await owing(1);
      final result = await fees.collect(
        studentId: student.id,
        amount: 4000,
        method: PaymentMethod.cash,
        accountId: cashId,
      );
      await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 8, 1),
      );
      expect((await fees.duesFor(student)).totalDue, 1000);

      await fees.cancelPayment(result.payment, reason: 'Wrong student');

      // Both July and the part of August the advance covered are owed again.
      expect((await fees.duesFor(student)).totalDue, 5000);
      expect((await fees.duesFor(student)).creditBalance, 0);
    });

    test('a duplicate receipt says what the original said', () async {
      final student = await owing(1); // July
      final result = await fees.collect(
        studentId: student.id,
        amount: 4000,
        method: PaymentMethod.cash,
        accountId: cashId,
      );

      // The advance is later spent on August.
      await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 8, 1),
      );

      // The original said "July, ৳1500 kept as advance". A reprint must not
      // start claiming the receipt was for July and August.
      final id = result.payment.id;
      expect(await fees.periodsSettledBy(id), ['2026-07']);
      expect(await fees.advanceCreatedBy(id), 1500);
      expect(
        await fees.periodsSettledBy(id, includeAdvance: true),
        ['2026-07', '2026-08'],
      );
    });

    test('voiding a multi-month payment puts every month back', () async {
      final student = await owing(3);
      final result = await fees.collect(
        studentId: student.id,
        amount: 7500,
        method: PaymentMethod.cash,
        accountId: cashId,
      );
      expect((await fees.duesFor(student)).totalDue, 0);

      await fees.cancelPayment(result.payment, reason: 'Entered twice');

      expect((await fees.duesFor(student)).totalDue, 7500);
      final invoices = await db.select(db.invoices).get();
      expect(invoices.every((i) => i.paidAmount == 0), isTrue);
      expect(invoices.every((i) => i.status == InvoiceStatus.unpaid), isTrue);

      // The receipt number is spent for good, and the ledger nets to nothing.
      expect(await ledger.balanceOf(cashId), 0);
    });

    test('an overpayment credit dies with the payment that made it', () async {
      final student = await owing(1);
      final result = await fees.collect(
        studentId: student.id,
        amount: 4000,
        method: PaymentMethod.cash,
        accountId: cashId,
      );
      expect(await db.select(db.studentCredits).get(), hasLength(1));

      await fees.cancelPayment(result.payment, reason: 'Wrong student');

      final live = await (db.select(db.studentCredits)
            ..where((t) => t.deletedAt.isNull()))
          .get();
      expect(live, isEmpty);
    });
  });

  group('Release 2 — §0.2–§0.6 defects', () {
    test('a day closing respects the month lock like every other write',
        () async {
      final locks = PeriodLockService(db: db, deviceId: device);
      await locks.lock(DateTime(2026, 3, 1), by: 'Owner');

      // Every other money write already asserted this; closeDay did not, so a
      // closed month could still be re-closed with different figures.
      await expectLater(
        expenses.closeDay(
          accountId: cashId,
          countedAmount: 1000,
          forDay: DateTime(2026, 3, 20),
        ),
        throwsA(isA<PeriodLockedException>()),
      );
    });

    test('receipt numbers follow the configured prefix', () async {
      final student = await admit('Rahim');

      // The centre renames its receipt book mid-year.
      await db.into(db.settings).insert(
            SettingsCompanion.insert(
              key: AppSettings.receiptPrefix,
              value: const Value('AEC'),
              deviceId: device,
            ),
          );

      final payment = (await fees.collect(
        studentId: student.id,
        amount: 100,
        method: PaymentMethod.cash,
        accountId: cashId,
      )).payment;

      // Previously this read "the first row of receipt_series" and would have
      // handed back R-00001 from the old book.
      expect(payment.receiptNo, startsWith('AEC-'));

      final series = await db.select(db.receiptSeries).get();
      expect(series.map((r) => r.prefix), containsAll(<String>['R', 'AEC']));
    });

    test('correcting attendance records what each mark used to be', () async {
      final student = await admit('Rahim');
      final attendance = AttendanceService(db: db, deviceId: device);

      final session = await attendance.openSession(
        batchId: batchId,
        on: DateTime(2026, 3, 2),
      );
      await attendance.saveSession(
        sessionId: session.id,
        states: {student.id: AttendanceState.absent},
      );

      // The guardian rings to say the child was there; the register is fixed.
      await attendance.saveSession(
        sessionId: session.id,
        states: {student.id: AttendanceState.present},
      );

      // The detail lives in the audit log; change_log carries the sync oplog.
      final log = await (db.select(db.auditLog)
            ..where((t) => t.entityId.equals(session.id)))
          .get();

      final correction =
          log.where((c) => c.action == 'attendance_corrected').single;
      expect(correction.beforeJson, contains('absent'));
      expect(correction.afterJson, contains('absent→present'));

      // The first save is not a correction: no before-state, and no list of
      // every student as "changed".
      final first = log.where((c) => c.action == 'attendance_saved').single;
      expect(first.beforeJson, isNull);
      expect(first.afterJson, isNot(contains('changed')));
    });

    test('saving an unchanged register is not logged as a correction',
        () async {
      final student = await admit('Rahim');
      final attendance = AttendanceService(db: db, deviceId: device);
      final session = await attendance.openSession(
        batchId: batchId,
        on: DateTime(2026, 3, 2),
      );
      final marks = {student.id: AttendanceState.present};

      await attendance.saveSession(sessionId: session.id, states: marks);
      await attendance.saveSession(sessionId: session.id, states: marks);

      final actions = (await (db.select(db.auditLog)
                ..where((t) => t.entityId.equals(session.id)))
              .get())
          .map((c) => c.action);
      expect(actions, isNot(contains('attendance_corrected')));
      expect(actions, contains('attendance_resaved'));
    });

    test('a student dropped from a saved register is recorded', () async {
      final rahim = await admit('Rahim');
      final karima = await admit('Karima');
      final attendance = AttendanceService(db: db, deviceId: device);
      final session = await attendance.openSession(
        batchId: batchId,
        on: DateTime(2026, 3, 2),
      );

      await attendance.saveSession(sessionId: session.id, states: {
        rahim.id: AttendanceState.present,
        karima.id: AttendanceState.present,
      });
      await attendance.saveSession(sessionId: session.id, states: {
        rahim.id: AttendanceState.present,
      });

      final correction = (await (db.select(db.auditLog)
                ..where((t) => t.entityId.equals(session.id)))
              .get())
          .where((c) => c.action == 'attendance_corrected')
          .single;
      expect(correction.afterJson, contains('present→removed'));
      expect(correction.afterJson, contains(karima.id));
    });
  });

  group('money in and money out', () {
    test('voiding a fee reduces what was collected — it is not spending',
        () async {
      final student = await admit('Rahim');
      final result = await fees.collect(
        studentId: student.id,
        amount: 2000,
        method: PaymentMethod.cash,
        accountId: cashId,
      );
      await fees.cancelPayment(result.payment, reason: 'Wrong student');

      final now = DateTime.now();
      final totals = await ledger.totalsBetween(
        DateTime(now.year, now.month, now.day),
        DateTime(now.year, now.month, now.day + 1),
      );

      // The Finance screen used to read "Collected ৳2000, Spent ৳2000" for
      // this — an expense that never happened.
      expect(totals.income, 0);
      expect(totals.expense, 0);
    });

    test('voiding an expense reduces spending — it is not income', () async {
      final head = (await db.select(db.expenseHeads).get()).first;
      final expense = await expenses.record(
        headId: head.id,
        accountId: cashId,
        amount: 800,
      );
      await expenses.cancel(expense, reason: 'Entered twice');

      final now = DateTime.now();
      final totals = await ledger.totalsBetween(
        DateTime(now.year, now.month, now.day),
        DateTime(now.year, now.month, now.day + 1),
      );
      expect(totals.income, 0);
      expect(totals.expense, 0);
    });

    test('moving money between accounts is neither income nor expense',
        () async {
      final bkash = (await db.select(db.accounts).get())
          .firstWhere((a) => a.kind == AccountKind.bkash);
      final now = DateTime.now();
      await ledger.post(
        accountId: cashId,
        amount: -1000,
        kind: LedgerKind.transfer,
        occurredOn: now,
      );
      await ledger.post(
        accountId: bkash.id,
        amount: 1000,
        kind: LedgerKind.transfer,
        occurredOn: now,
      );

      final totals = await ledger.totalsBetween(
        DateTime(now.year, now.month, now.day),
        DateTime(now.year, now.month, now.day + 1),
      );
      expect(totals.income, 0);
      expect(totals.expense, 0);
    });
  });

  // ===================== Stage 5 =====================

  group('Stage 5 — fees and receipts', () {
    test('monthly billing raises one invoice per student per month', () async {
      await admit('Rahim');
      await admit('Karima');

      final created = await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 3, 1),
      );
      expect(created, 2);

      // Running it again must not double-charge anyone.
      final again = await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 3, 1),
      );
      expect(again, 0);
      expect(await db.select(db.invoices).get(), hasLength(2));
    });

    test('raising fees names the students it could not bill', () async {
      // A centre fresh from setup: the batch has no fee and neither does the
      // student. Previously this reported "everyone was already billed".
      await (db.update(db.batches)..where((t) => t.id.equals(batchId)))
          .write(const BatchesCompanion(monthlyFee: Value(0)));
      await admit('Rahim');

      final result = await fees.raiseMonthlyFees(
        sessionId: sessionId,
        forMonth: DateTime(2026, 3, 1),
      );

      expect(result.created, 0);
      expect(result.alreadyBilled, 0);
      expect(result.withoutFee, ['Rahim']);
    });

    test('a second run reports who was already billed', () async {
      await admit('Rahim');
      await fees.raiseMonthlyFees(
        sessionId: sessionId,
        forMonth: DateTime(2026, 3, 1),
      );
      final again = await fees.raiseMonthlyFees(
        sessionId: sessionId,
        forMonth: DateTime(2026, 3, 1),
      );
      expect(again.created, 0);
      expect(again.alreadyBilled, 1);
      expect(again.withoutFee, isEmpty);
    });

    test("invoices fall due on the centre's own day, not a built-in one",
        () async {
      await admit('Rahim');
      await AppSettings(db: db, deviceId: device)
          .write(AppSettings.defaultDueDay, '5');

      await fees.raiseMonthlyFees(
        sessionId: sessionId,
        forMonth: DateTime(2026, 3, 1),
      );

      final invoice = (await db.select(db.invoices).get()).single;
      expect(invoice.dueOn, DateTime(2026, 3, 5));
    });

    test('a discount reduces the invoice and is recorded', () async {
      final student = await admit('Rahim');
      await db.into(db.discounts).insert(
            DiscountsCompanion.insert(
              studentId: student.id,
              amount: 500,
              deviceId: device,
              reason: const Value('Sibling'),
              approvedBy: const Value('Owner'),
            ),
          );

      await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 3, 1),
      );

      final invoice = (await db.select(db.invoices).get()).single;
      expect(invoice.grossAmount, 2500);
      expect(invoice.discountAmount, 500);
      expect(invoice.netAmount, 2000);
    });

    test('receipt numbers are gapless and never reused', () async {
      final student = await admit('Rahim');
      final receipts = <String>[];
      for (var i = 0; i < 5; i++) {
        final p = (await fees.collect(
          studentId: student.id,
          amount: 500,
          method: PaymentMethod.cash,
          accountId: cashId,
        )).payment;
        receipts.add(p.receiptNo);
      }

      expect(receipts, [
        'R-00001',
        'R-00002',
        'R-00003',
        'R-00004',
        'R-00005',
      ]);

      // Cancelling keeps the number used — a gap is what an auditor asks about.
      final third = (await db.select(db.payments).get())
          .firstWhere((p) => p.receiptNo == 'R-00003');
      await fees.cancelPayment(third, reason: 'Counted twice');

      final next = (await fees.collect(
        studentId: student.id,
        amount: 100,
        method: PaymentMethod.cash,
        accountId: cashId,
      )).payment;
      expect(next.receiptNo, 'R-00006');
    });

    test('a partial payment leaves the right amount owing', () async {
      final student = await admit('Rahim');
      await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 3, 1),
      );
      final invoice = (await db.select(db.invoices).get()).single;

      await fees.collect(
        studentId: student.id,
        invoiceId: invoice.id,
        amount: 1000,
        method: PaymentMethod.cash,
        accountId: cashId,
      );

      final after = (await db.select(db.invoices).get()).single;
      expect(after.paidAmount, 1000);
      expect(after.status, InvoiceStatus.partial);

      final due = await fees.duesFor(student);
      expect(due.totalDue, 1500);
      expect(due.monthsBehind, 1);
    });

    test('paying in full closes the invoice', () async {
      final student = await admit('Rahim');
      await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 3, 1),
      );
      final invoice = (await db.select(db.invoices).get()).single;

      await fees.collect(
        studentId: student.id,
        invoiceId: invoice.id,
        amount: 2500,
        method: PaymentMethod.cash,
        accountId: cashId,
      );

      expect((await db.select(db.invoices).get()).single.status,
          InvoiceStatus.paid);
      expect((await fees.duesFor(student)).totalDue, 0);
      expect(await fees.outstandingTotal(), 0);
    });

    test('defaulters are listed worst first', () async {
      final a = await admit('Rahim');
      final b = await admit('Karima');
      for (final month in [DateTime(2026, 1, 1), DateTime(2026, 2, 1)]) {
        await fees.generateMonthlyInvoices(
            sessionId: sessionId, forMonth: month);
      }
      // Karima clears January.
      final karimaInvoice = (await db.select(db.invoices).get())
          .firstWhere((i) => i.studentId == b.id && i.periodKey == '2026-01');
      await fees.collect(
        studentId: b.id,
        invoiceId: karimaInvoice.id,
        amount: 2500,
        method: PaymentMethod.cash,
        accountId: cashId,
      );

      final list = await fees.defaulters();
      expect(list.first.student.id, a.id);
      expect(list.first.totalDue, 5000);
      expect(list.last.totalDue, 2500);
    });

    test('a receipt renders with amount in words and correct grouping',
        () async {
      final student = await admit('Rahim Ahmed');
      final payment = (await fees.collect(
        studentId: student.id,
        amount: 125000,
        method: PaymentMethod.bkash,
        accountId: cashId,
        receivedBy: 'Reception',
      )).payment;

      final html = ReceiptDocument(engine: const DocumentEngine())
          .build(payment: payment, student: student, previousDue: 130000);

      expect(html, contains('MONEY RECEIPT'));
      expect(html, contains(payment.receiptNo));
      expect(html, contains('Rahim Ahmed'));
      expect(html, contains('bKash'));
      // South Asian grouping, not 125,000.
      expect(html, contains('1,25,000'));
      expect(html, contains('One lakh twenty-five thousand taka only'));
      // Previous due 130000 - paid 125000
      expect(html, contains('5,000'));
    });

    test('a reprint is stamped so it cannot pass as the original', () {
      const engine = DocumentEngine();
      final student = Student(
        id: 's1', code: 'AEC-1', name: 'Rahim', nameAlt: '',
        photoPath: null, dateOfBirth: null, gender: null, school: '',
        studentPhone: '', studentPhoneNorm: '', guardianName: '',
        guardianRelation: '', guardianPhone: '', guardianPhoneNorm: '',
        address: '', bloodGroup: '', admissionDate: DateTime(2026),
        status: StudentStatus.active, monthlyFee: 0, referredBy: '', notes: '',
        createdAt: DateTime(2026), updatedAt: DateTime(2026),
        deletedAt: null, deviceId: device,
      );
      final payment = Payment(
        id: 'p1', receiptNo: 'R-00001', studentId: 's1', invoiceId: null,
        amount: 500, method: PaymentMethod.cash, accountId: 'a1',
        reference: '', receivedOn: DateTime(2026), receivedBy: '',
        forPeriod: '', isCancelled: false, cancelReason: '', note: '',
        createdAt: DateTime(2026), updatedAt: DateTime(2026),
        deletedAt: null, deviceId: device,
      );

      final original = ReceiptDocument(engine: engine)
          .build(payment: payment, student: student);
      final duplicate = ReceiptDocument(engine: engine)
          .build(payment: payment, student: student, isDuplicate: true);

      expect(original, isNot(contains('DUPLICATE')));
      expect(duplicate, contains('DUPLICATE'));
    });

    test('amount in words handles the lakh/crore system', () {
      expect(ReceiptDocument.takaInWords(0), 'Zero taka only');
      expect(ReceiptDocument.takaInWords(500), 'Five hundred taka only');
      expect(ReceiptDocument.takaInWords(2500),
          'Two thousand five hundred taka only');
      expect(ReceiptDocument.takaInWords(100000), 'One lakh taka only');
      expect(ReceiptDocument.takaInWords(10000000), 'One crore taka only');
    });
  });

  // ===================== Stage 6 =====================

  group('Stage 6 — finance', () {
    test('a payment moves money into the account it was taken in', () async {
      final student = await admit('Rahim');
      expect(await ledger.balanceOf(cashId), 0);

      await fees.collect(
        studentId: student.id,
        amount: 2500,
        method: PaymentMethod.cash,
        accountId: cashId,
      );
      expect(await ledger.balanceOf(cashId), 2500);
    });

    test('an expense takes money out', () async {
      final head = (await db.select(db.expenseHeads).get()).first;
      await expenses.record(headId: head.id, accountId: cashId, amount: 800);
      expect(await ledger.balanceOf(cashId), -800);
    });

    test('the gate: balances reconcile after a void', () async {
      final student = await admit('Rahim');
      final head = (await db.select(db.expenseHeads).get()).first;

      final p1 = (await fees.collect(
        studentId: student.id,
        amount: 2500,
        method: PaymentMethod.cash,
        accountId: cashId,
      )).payment;
      await fees.collect(
        studentId: student.id,
        amount: 1500,
        method: PaymentMethod.cash,
        accountId: cashId,
      );
      await expenses.record(headId: head.id, accountId: cashId, amount: 1000);

      expect(await ledger.balanceOf(cashId), 2500 + 1500 - 1000);

      await fees.cancelPayment(p1, reason: 'Receipt written twice');

      expect(
        await ledger.balanceOf(cashId),
        1500 - 1000,
        reason: 'the cancelled receipt must leave the balance',
      );

      // The original entry is still there; a reversal was added beside it.
      final entries = await db.select(db.ledgerEntries).get();
      expect(entries, hasLength(4));
      final reversal = entries.singleWhere((e) => e.reversesId != null);
      expect(reversal.amount, -2500);

      // And the payment row itself survives, flagged.
      final cancelled = (await db.select(db.payments).get())
          .firstWhere((p) => p.id == p1.id);
      expect(cancelled.isCancelled, isTrue);
      expect(cancelled.cancelReason, 'Receipt written twice');
      expect(cancelled.amount, 2500, reason: 'the row is never edited');
    });

    test('cancelling twice does not double-reverse', () async {
      final student = await admit('Rahim');
      final payment = (await fees.collect(
        studentId: student.id,
        amount: 2000,
        method: PaymentMethod.cash,
        accountId: cashId,
      )).payment;

      await fees.cancelPayment(payment, reason: 'Mistake');
      final refreshed = (await db.select(db.payments).get()).single;
      await fees.cancelPayment(refreshed, reason: 'Mistake again');

      expect(await ledger.balanceOf(cashId), 0);
      expect(await db.select(db.ledgerEntries).get(), hasLength(2));
    });

    test('day closing records the difference it found', () async {
      final student = await admit('Rahim');
      await fees.collect(
        studentId: student.id,
        amount: 3000,
        method: PaymentMethod.cash,
        accountId: cashId,
      );

      final closing = await expenses.closeDay(
        accountId: cashId,
        countedAmount: 2800,
        note: 'Two hundred short',
      );

      expect(closing.expectedAmount, 3000);
      expect(closing.countedAmount, 2800);
      expect(closing.difference, -200);
    });

    test('salary leaves the account and is attributed', () async {
      final teacher = await db.into(db.staff).insertReturning(
            StaffCompanion.insert(
              name: 'Mr Rahman',
              joinDate: DateTime(2026, 1, 1),
              payModel: PayModel.monthly,
              deviceId: device,
              monthlySalary: const Value(20000),
            ),
          );
      await expenses.paySalary(
        staffId: teacher.id,
        accountId: cashId,
        periodKey: '2026-03',
        grossAmount: 20000,
        deductions: 500,
      );

      expect(await ledger.balanceOf(cashId), -19500);
      expect((await db.select(db.salaryPayments).get()).single.netAmount, 19500);
    });
  });

  // ===================== Stage 7 =====================

  group('Stage 7 — attendance', () {
    test('a class of 40 saves as one batched write, quickly', () async {
      final roster = <Student>[];
      for (var i = 0; i < 40; i++) {
        roster.add(await admit('Student $i'));
      }

      final service =
          AttendanceService(db: db, deviceId: device);
      final session = await service.openSession(batchId: batchId);

      // The screen opens everyone present; the teacher touches the exceptions.
      final states = {
        for (final s in roster) s.id: AttendanceState.present,
      };
      states[roster[3].id] = AttendanceState.absent;
      states[roster[11].id] = AttendanceState.late;

      final watch = Stopwatch()..start();
      await service.saveSession(sessionId: session.id, states: states);
      final ms = watch.elapsedMilliseconds;

      final saved = await service.statesFor(session.id);
      expect(saved, hasLength(40));
      expect(saved[roster[3].id], AttendanceState.absent);
      expect(saved[roster[11].id], AttendanceState.late);
      expect(ms, lessThan(1000), reason: 'save took ${ms}ms');
    });

    test('re-saving replaces rather than duplicating', () async {
      final student = await admit('Rahim');
      final service = AttendanceService(db: db, deviceId: device);
      final session = await service.openSession(batchId: batchId);

      await service.saveSession(
        sessionId: session.id,
        states: {student.id: AttendanceState.absent},
      );
      await service.saveSession(
        sessionId: session.id,
        states: {student.id: AttendanceState.present},
      );

      final rows = await db.select(db.attendanceRecords).get();
      expect(rows, hasLength(1));
      expect(rows.single.state, AttendanceState.present);
    });

    test('opening a session twice on one day reuses it', () async {
      final service = AttendanceService(db: db, deviceId: device);
      final a = await service.openSession(batchId: batchId);
      final b = await service.openSession(batchId: batchId);
      expect(a.id, b.id);
    });

    test('late counts as attended for the percentage', () async {
      final student = await admit('Rahim');
      final service = AttendanceService(db: db, deviceId: device);

      for (final (day, state) in [
        (DateTime(2026, 3, 1), AttendanceState.present),
        (DateTime(2026, 3, 2), AttendanceState.late),
        (DateTime(2026, 3, 3), AttendanceState.absent),
        (DateTime(2026, 3, 4), AttendanceState.present),
      ]) {
        final session = await service.openSession(batchId: batchId, on: day);
        await service.saveSession(
            sessionId: session.id, states: {student.id: state});
      }

      final summary = await service.summaryFor(studentId: student.id);
      expect(summary.held, 4);
      expect(summary.present, 3);
      expect(summary.percent, 75);
    });

    test('flags students absent three classes running', () async {
      final drifting = await admit('Drifting');
      final steady = await admit('Steady');
      final service = AttendanceService(db: db, deviceId: device);

      for (final day in [
        DateTime(2026, 3, 1),
        DateTime(2026, 3, 2),
        DateTime(2026, 3, 3),
      ]) {
        final session = await service.openSession(batchId: batchId, on: day);
        await service.saveSession(sessionId: session.id, states: {
          drifting.id: AttendanceState.absent,
          steady.id: AttendanceState.present,
        });
      }

      final flagged = await service.consecutivelyAbsent();
      expect(flagged.map((s) => s.id), [drifting.id]);
    });
  });

  // ===================== Stage 8 =====================

  group('Stage 8 — inventory', () {
    test('stock moves keep the running total honest', () async {
      final service = InventoryService(db: db, deviceId: device);
      final item = await service.addItem(
        name: 'A4 paper',
        unit: 'ream',
        openingQuantity: 10,
        minimumQuantity: 3,
      );

      await service.move(
          item: item, move: StockMove.receive, quantity: 20, reason: 'Purchase');
      var current = (await db.select(db.inventoryItems).get()).single;

      await service.move(
          item: current, move: StockMove.issue, quantity: 5, reason: 'Exams');
      current = (await db.select(db.inventoryItems).get()).single;

      await service.move(
          item: current, move: StockMove.damage, quantity: 2, reason: 'Water');
      current = (await db.select(db.inventoryItems).get()).single;

      expect(current.currentQuantity, 23);
      expect(
        await service.quantityFromHistory(item.id),
        23,
        reason: 'the running total must match the movements that produced it',
      );
    });

    test('issue and damage remove stock whatever sign is given', () async {
      final service = InventoryService(db: db, deviceId: device);
      final item = await service.addItem(name: 'Markers', openingQuantity: 10);

      await service.move(item: item, move: StockMove.issue, quantity: -3);
      expect((await db.select(db.inventoryItems).get()).single.currentQuantity, 7);
    });

    test('low stock lists what needs reordering', () async {
      final service = InventoryService(db: db, deviceId: device);
      await service.addItem(
          name: 'A4 paper', openingQuantity: 2, minimumQuantity: 5);
      await service.addItem(
          name: 'Toner', openingQuantity: 9, minimumQuantity: 2);

      final low = await service.lowStock();
      expect(low.map((i) => i.name), ['A4 paper']);
    });
  });

  // ===================== the full workflow =====================

  group('the payment workflow, end to end', () {
    test('searchable, paid, reflected, backed up, restored', () async {
      final tmp = await Directory.systemTemp.createTemp('workflow');
      addTearDown(() => tmp.delete(recursive: true));

      // Searchable
      final student = await admit('Rahim Ahmed');
      expect((await students.search('01712345678')).single.id, student.id);

      // Billed and paid
      await fees.generateMonthlyInvoices(
          sessionId: sessionId, forMonth: DateTime(2026, 3, 1));
      final invoice = (await db.select(db.invoices).get()).single;
      final payment = (await fees.collect(
        studentId: student.id,
        invoiceId: invoice.id,
        amount: 2500,
        method: PaymentMethod.cash,
        accountId: cashId,
        forPeriod: 'March 2026',
      )).payment;

      // Due updated, finance updated, receipt allocated
      expect((await fees.duesFor(student)).totalDue, 0);
      expect(await ledger.balanceOf(cashId), 2500);
      expect(payment.receiptNo, 'R-00001');

      // Reflected in the day's report
      final today = await fees.paymentsOn(payment.receivedOn);
      expect(today.single.id, payment.id);

      // Backed up
      final archive = await const BackupService().create(
        db: db,
        destination: tmp,
        deviceId: device,
      );

      // ...and restored somewhere else, with the money intact
      final target = File('${tmp.path}/restored/app.db');
      await const BackupService().restore(
        archiveFile: archive,
        passphrase: '',
        targetDbFile: target,
      );

      final restored = AppDatabase.encrypted(file: target, encryptionKey: '');
      final restoredPayments = await restored.select(restored.payments).get();
      final restoredLedger =
          LedgerService(db: restored, deviceId: device);
      final balance = await restoredLedger.balanceOf(cashId);
      final restoredInvoice = (await restored.select(restored.invoices).get())
          .single;
      await restored.close();

      expect(restoredPayments.single.receiptNo, 'R-00001');
      expect(restoredPayments.single.amount, 2500);
      expect(balance, 2500);
      expect(restoredInvoice.status, InvoiceStatus.paid);
    });
  });
}
