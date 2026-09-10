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
        final p = await fees.collect(
          studentId: student.id,
          amount: 500,
          method: PaymentMethod.cash,
          accountId: cashId,
        );
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

      final next = await fees.collect(
        studentId: student.id,
        amount: 100,
        method: PaymentMethod.cash,
        accountId: cashId,
      );
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
      final payment = await fees.collect(
        studentId: student.id,
        amount: 125000,
        method: PaymentMethod.bkash,
        accountId: cashId,
        receivedBy: 'Reception',
      );

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

      final p1 = await fees.collect(
        studentId: student.id,
        amount: 2500,
        method: PaymentMethod.cash,
        accountId: cashId,
      );
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
      final payment = await fees.collect(
        studentId: student.id,
        amount: 2000,
        method: PaymentMethod.cash,
        accountId: cashId,
      );

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
      final payment = await fees.collect(
        studentId: student.id,
        invoiceId: invoice.id,
        amount: 2500,
        method: PaymentMethod.cash,
        accountId: cashId,
        forPeriod: 'March 2026',
      );

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
