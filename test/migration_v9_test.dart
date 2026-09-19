import 'dart:io';

import 'package:coaching_ops/data/db/database.dart';
import 'package:coaching_ops/data/db/tables.dart';
import 'package:coaching_ops/data/finance/fee_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Upgrading a real v8 database to v9.
///
/// v8 attached every payment to a single invoice. A centre upgrading carries
/// that history with it — including the exact mistake v9 exists to fix: one
/// payment covering three months recorded as an overpaid first month and two
/// unpaid ones. The upgrade has to repair those figures, not preserve them.
void main() {
  late Directory dir;
  late File file;

  const device = 'device-a';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('coaching_v9_');
    file = File('${dir.path}/app.db');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// Builds a database, writes history the way v8 wrote it, then rewinds the
  /// schema to v8 so the next open runs the real upgrade path.
  Future<({String paidUp, String split, String early})> seedAsV8() async {
    final db = AppDatabase(NativeDatabase(file));

    final session = await db.into(db.academicSessions).insertReturning(
          AcademicSessionsCompanion.insert(
            name: '2026',
            startDate: DateTime(2026, 1, 1),
            endDate: DateTime(2026, 12, 31),
            deviceId: device,
            isActive: const Value(true),
          ),
        );
    final fees = FeeService(db: db, deviceId: device);
    await fees.ensureDefaults();
    final cash = (await db.select(db.accounts).get())
        .firstWhere((a) => a.kind == AccountKind.cash);

    Future<Student> student(String name, String code) =>
        db.into(db.students).insertReturning(
              StudentsCompanion.insert(
                code: code,
                name: name,
                admissionDate: DateTime(2026, 1, 1),
                status: StudentStatus.active,
                deviceId: device,
              ),
            );

    Future<Invoice> invoice(Student s, String period, int net) =>
        db.into(db.invoices).insertReturning(
              InvoicesCompanion.insert(
                studentId: s.id,
                sessionId: session.id,
                periodKey: period,
                issuedOn: DateTime(2026, 7, 1),
                status: InvoiceStatus.unpaid,
                deviceId: device,
                grossAmount: Value(net),
                netAmount: Value(net),
              ),
            );

    var receipt = 1;
    Future<void> paidTheV8Way(Student s, Invoice target, int amount,
        DateTime on) async {
      await db.into(db.payments).insert(
            PaymentsCompanion.insert(
              receiptNo: 'R-${(receipt++).toString().padLeft(5, '0')}',
              studentId: s.id,
              amount: amount,
              method: PaymentMethod.cash,
              accountId: cash.id,
              receivedOn: on,
              deviceId: device,
              invoiceId: Value(target.id),
            ),
          );
    }

    // Rahim owed July, August and September and paid all three at once. v8
    // pinned the whole ৳3000 on July.
    final rahim = await student('Rahim', 'A-1');
    final july = await invoice(rahim, '2026-07', 1000);
    await invoice(rahim, '2026-08', 1000);
    await invoice(rahim, '2026-09', 1000);
    await paidTheV8Way(rahim, july, 3000, DateTime(2026, 7, 5));
    await (db.update(db.invoices)..where((t) => t.id.equals(july.id))).write(
      const InvoicesCompanion(
        paidAmount: Value(3000),
        status: Value(InvoiceStatus.paid),
      ),
    );

    // Karima paid one ৳2500 month in two halves of ৳1500 — ৳500 too much,
    // which v8 also recorded against that one month.
    final karima = await student('Karima', 'A-2');
    final march = await invoice(karima, '2026-03', 2500);
    await paidTheV8Way(karima, march, 1500, DateTime(2026, 3, 2));
    await paidTheV8Way(karima, march, 1500, DateTime(2026, 3, 9));
    await (db.update(db.invoices)..where((t) => t.id.equals(march.id))).write(
      const InvoicesCompanion(
        paidAmount: Value(3000),
        status: Value(InvoiceStatus.paid),
      ),
    );

    // Nadia paid ৳5000 on the day she joined, before the centre had set any
    // fees — so v8 attached it to nothing. A centre starting from scratch
    // does exactly this.
    final nadia = await student('Nadia', 'A-3');
    await db.into(db.payments).insert(
          PaymentsCompanion.insert(
            receiptNo: 'R-${(receipt++).toString().padLeft(5, '0')}',
            studentId: nadia.id,
            amount: 5000,
            method: PaymentMethod.cash,
            accountId: cash.id,
            receivedOn: DateTime(2026, 6, 1),
            deviceId: device,
          ),
        );
    await invoice(nadia, '2026-07', 1500);

    // Rewind to the v8 schema.
    await db.customStatement('DROP TABLE payment_allocations');
    await db.customStatement('DROP TABLE student_credits');
    await db.customStatement('PRAGMA user_version = 8');
    await db.close();

    return (paidUp: rahim.id, split: karima.id, early: nadia.id);
  }

  test('a v8 multi-month payment is repaired, not preserved', () async {
    final ids = await seedAsV8();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final fees = FeeService(db: db, deviceId: device);

    final rahim = await (db.select(db.students)
          ..where((t) => t.id.equals(ids.paidUp)))
        .getSingle();
    final due = await fees.duesFor(rahim);

    // He paid ৳3000 against ৳3000. Nothing is owed and no month is overpaid.
    expect(due.totalDue, 0, reason: 'v8 left Aug and Sep unpaid');
    expect(due.monthsBehind, 0);

    final invoices = await (db.select(db.invoices)
          ..where((t) => t.studentId.equals(ids.paidUp)))
        .get();
    for (final i in invoices) {
      expect(i.paidAmount, i.netAmount, reason: i.periodKey);
      expect(i.status, InvoiceStatus.paid, reason: i.periodKey);
    }
  });

  test('two part payments never add up to more than the invoice', () async {
    final ids = await seedAsV8();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final march = (await (db.select(db.invoices)
              ..where((t) => t.studentId.equals(ids.split)))
            .get())
        .single;
    expect(march.paidAmount, 2500);
    expect(march.status, InvoiceStatus.paid);

    final allocated = (await (db.select(db.paymentAllocations)
              ..where((t) => t.invoiceId.equals(march.id)))
            .get())
        .fold<int>(0, (sum, a) => sum + a.amount);
    expect(allocated, 2500);

    // The ৳500 surplus is not lost: it is held for her.
    final credit = await (db.select(db.studentCredits)
          ..where((t) => t.studentId.equals(ids.split)))
        .get();
    expect(credit.fold<int>(0, (sum, c) => sum + c.amount), 500);
  });

  test('money taken before any fee was set becomes an advance', () async {
    final ids = await seedAsV8();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final fees = FeeService(db: db, deviceId: device);

    final nadia = await (db.select(db.students)
          ..where((t) => t.id.equals(ids.early)))
        .getSingle();
    final due = await fees.duesFor(nadia);

    // ৳5000 paid, ৳1500 billed since: July is covered, ৳3500 is held.
    expect(due.totalDue, 0);
    expect(due.creditBalance, 3500);
  });

  test('every payment is fully accounted for after the upgrade', () async {
    await seedAsV8();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    // Allocated + credited must equal what was received, payment by payment.
    for (final p in await db.select(db.payments).get()) {
      final allocated = (await (db.select(db.paymentAllocations)
                ..where((t) => t.paymentId.equals(p.id)))
              .get())
          .fold<int>(0, (sum, a) => sum + a.amount);
      final credited = (await (db.select(db.studentCredits)
                ..where((t) => t.paymentId.equals(p.id)))
              .get())
          .fold<int>(0, (sum, c) => sum + c.amount);
      expect(allocated + credited, p.amount, reason: p.receiptNo);
    }
  });

  test('a pre-release v9 database is repaired on the way to v10', () async {
    // What the emulator actually had: a payment taken before any fee was
    // set, which the first v9 backfill skipped — so it was allocated to
    // nothing and counted for nothing.
    var db = AppDatabase(NativeDatabase(file));
    final session = await db.into(db.academicSessions).insertReturning(
          AcademicSessionsCompanion.insert(
            name: '2026',
            startDate: DateTime(2026, 1, 1),
            endDate: DateTime(2026, 12, 31),
            deviceId: device,
            isActive: const Value(true),
          ),
        );
    final fees = FeeService(db: db, deviceId: device);
    await fees.ensureDefaults();
    final cash = (await db.select(db.accounts).get())
        .firstWhere((a) => a.kind == AccountKind.cash);
    final student = await db.into(db.students).insertReturning(
          StudentsCompanion.insert(
            code: 'A-1',
            name: 'Rahim',
            admissionDate: DateTime(2026, 1, 1),
            status: StudentStatus.active,
            deviceId: device,
          ),
        );
    await db.into(db.payments).insert(
          PaymentsCompanion.insert(
            receiptNo: 'R-00001',
            studentId: student.id,
            amount: 5000,
            method: PaymentMethod.cash,
            accountId: cash.id,
            receivedOn: DateTime(2026, 9, 11),
            deviceId: device,
            // Taken on the 11th; the fee was only raised on the 19th.
            createdAt: Value(DateTime(2026, 9, 11, 16)),
          ),
        );
    await db.into(db.invoices).insert(
          InvoicesCompanion.insert(
            studentId: student.id,
            sessionId: session.id,
            periodKey: '2026-09',
            issuedOn: DateTime(2026, 9, 19),
            status: InvoiceStatus.unpaid,
            deviceId: device,
            grossAmount: const Value(1500),
            netAmount: const Value(1500),
            createdAt: Value(DateTime(2026, 9, 19, 11)),
          ),
        );

    // Rewind to the pre-release v9 shape: no from_credit column, and no
    // allocation for the invoice-less payment.
    await db.customStatement(
        'ALTER TABLE payment_allocations DROP COLUMN from_credit');
    await db.customStatement('DELETE FROM payment_allocations');
    await db.customStatement('DELETE FROM student_credits');
    await db.customStatement('PRAGMA user_version = 9');
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final due = await FeeService(db: db, deviceId: device).duesFor(student);
    expect(due.totalDue, 0, reason: 'the ৳5000 already covers September');
    expect(due.creditBalance, 3500);

    // September was raised after the money came in, so it was paid from
    // advance — and a reprint of R-00001 will not claim it.
    final allocation = (await db.select(db.paymentAllocations).get()).single;
    expect(allocation.fromCredit, isTrue);
  });
}
