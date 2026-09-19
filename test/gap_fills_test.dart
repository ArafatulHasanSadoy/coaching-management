import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:coaching_ops/core/app_settings.dart';
import 'package:coaching_ops/data/academic/session_service.dart';
import 'package:coaching_ops/data/attendance/attendance_service.dart';
import 'package:coaching_ops/data/db/database.dart';
import 'package:coaching_ops/data/db/tables.dart';
import 'package:coaching_ops/data/documents/document_engine.dart';
import 'package:coaching_ops/data/finance/expense_service.dart';
import 'package:coaching_ops/data/finance/fee_service.dart';
import 'package:coaching_ops/data/finance/payroll_service.dart';
import 'package:coaching_ops/data/finance/period_lock_service.dart';
import 'package:coaching_ops/data/reports/reports_service.dart';
import 'package:coaching_ops/data/repositories/master_data_repository.dart';
import 'package:coaching_ops/data/students/csv_import.dart';
import 'package:coaching_ops/data/students/enquiry_service.dart';
import 'package:coaching_ops/data/students/students_repository.dart';
import 'package:coaching_ops/data/students/xlsx_reader.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

const device = 'device-a';

void main() {
  late AppDatabase db;
  late FeeService fees;
  late ExpenseService expenses;
  late StudentsRepository students;
  late MasterDataRepository master;
  late PeriodLockService locks;
  late String sessionId;
  late String classId;
  late String batchId;
  late String cashId;

  setUp(() async {
    db = AppDatabase.memory();
    fees = FeeService(db: db, deviceId: device);
    expenses = ExpenseService(db: db, deviceId: device);
    students = StudentsRepository(db: db, deviceId: device);
    master = MasterDataRepository(db: db, deviceId: device);
    locks = PeriodLockService(db: db, deviceId: device);

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
    classId = (await master.addClass('Class 9')).id;
    batchId = (await master.addBatch(
      sessionId: sessionId,
      classId: classId,
      name: 'Science A',
      monthlyFee: 2500,
    ))
        .id;
    await fees.ensureDefaults();
    cashId = (await db.select(db.accounts).get())
        .firstWhere((a) => a.kind == AccountKind.cash)
        .id;
  });

  tearDown(() => db.close());

  Future<Student> admit(String name, {String phone = '01712345678'}) =>
      students.admit(
        name: name,
        batchId: batchId,
        sessionId: sessionId,
        guardianPhone: phone,
      );

  group('month-end lock', () {
    test('a closed month refuses new money, and says which month', () async {
      final student = await admit('Rahim');
      await locks.lock(DateTime(2026, 3), by: 'Owner');

      await expectLater(
        fees.collect(
          studentId: student.id,
          amount: 2500,
          method: PaymentMethod.cash,
          accountId: cashId,
          receivedOn: DateTime(2026, 3, 15),
        ),
        throwsA(isA<PeriodLockedException>().having(
            (e) => e.periodKey, 'periodKey', '2026-03')),
      );

      final head = (await db.select(db.expenseHeads).get()).first;
      await expectLater(
        expenses.record(
          headId: head.id,
          accountId: cashId,
          amount: 100,
          spentOn: DateTime(2026, 3, 2),
        ),
        throwsA(isA<PeriodLockedException>()),
      );
    });

    test('other months carry on as normal', () async {
      final student = await admit('Rahim');
      await locks.lock(DateTime(2026, 3));

      final payment = (await fees.collect(
        studentId: student.id,
        amount: 2500,
        method: PaymentMethod.cash,
        accountId: cashId,
        receivedOn: DateTime(2026, 4, 1),
      )).payment;
      expect(payment.receiptNo, isNotEmpty);
    });

    test('reopening is allowed, and recorded', () async {
      final student = await admit('Rahim');
      await locks.lock(DateTime(2026, 3));
      final lock = (await locks.locked()).single;
      await locks.unlock(lock, reason: 'Late receipt found');

      final payment = (await fees.collect(
        studentId: student.id,
        amount: 500,
        method: PaymentMethod.cash,
        accountId: cashId,
        receivedOn: DateTime(2026, 3, 20),
      )).payment;
      expect(payment.amount, 500);

      final trail = await (db.select(db.auditLog)
            ..where((t) => t.action.equals('month_reopened')))
          .get();
      expect(trail.single.afterJson, contains('Late receipt found'));
    });

    test('a cancelled receipt in a closed month is refused too', () async {
      final student = await admit('Rahim');
      final payment = (await fees.collect(
        studentId: student.id,
        amount: 2500,
        method: PaymentMethod.cash,
        accountId: cashId,
        receivedOn: DateTime(2026, 3, 5),
      )).payment;
      await locks.lock(DateTime(2026, 3));

      await expectLater(
        fees.cancelPayment(payment, reason: 'Mistake'),
        throwsA(isA<PeriodLockedException>()),
      );
    });
  });

  group('per-class teacher pay', () {
    test('is computed from the classes actually taught', () async {
      final teacher = await db.into(db.staff).insertReturning(
            StaffCompanion.insert(
              name: 'Mr Karim',
              joinDate: DateTime(2026, 1, 1),
              payModel: PayModel.perClass,
              deviceId: device,
              perClassRate: const Value(400),
            ),
          );

      final attendance = AttendanceService(db: db, deviceId: device);
      for (final day in [
        DateTime(2026, 3, 2),
        DateTime(2026, 3, 4),
        DateTime(2026, 3, 6),
        // Outside the month — must not be counted.
        DateTime(2026, 4, 1),
      ]) {
        await attendance.openSession(
            batchId: batchId, on: day, staffId: teacher.id);
      }

      final payroll = PayrollService(db: db, deviceId: device);
      final line = (await payroll.payrollFor(DateTime(2026, 3))).single;

      expect(line.classesTaught, 3);
      expect(line.gross, 1200);
      expect(line.outstanding, 1200);
    });

    test('a monthly teacher is paid their salary, not their attendance',
        () async {
      await db.into(db.staff).insertReturning(
            StaffCompanion.insert(
              name: 'Ms Nabila',
              joinDate: DateTime(2026, 1, 1),
              payModel: PayModel.monthly,
              deviceId: device,
              monthlySalary: const Value(20000),
            ),
          );

      final line = (await PayrollService(db: db, deviceId: device)
              .payrollFor(DateTime(2026, 3)))
          .single;
      expect(line.gross, 20000);
      expect(line.classesTaught, 0);
    });

    test('what has already been paid is netted off', () async {
      final teacher = await db.into(db.staff).insertReturning(
            StaffCompanion.insert(
              name: 'Mr Karim',
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
        grossAmount: 8000,
        paidOn: DateTime(2026, 3, 15),
      );

      final line = (await PayrollService(db: db, deviceId: device)
              .payrollFor(DateTime(2026, 3)))
          .single;
      expect(line.alreadyPaid, 8000);
      expect(line.outstanding, 12000);
    });
  });

  group('year-end rollover', () {
    test('carries students forward and leaves last year untouched', () async {
      final a = await admit('Rahim');
      final b = await admit('Karima');
      await fees.generateMonthlyInvoices(
          sessionId: sessionId, forMonth: DateTime(2026, 3));

      final service = SessionService(db: db, deviceId: device);
      final old = (await service.all()).single;
      final plan = await service.planRollover(old);
      expect(plan.batches, hasLength(1));
      expect(plan.studentCount, 2);

      final next = await service.rollOver(
        from: old,
        newName: '2027',
        startDate: DateTime(2027, 1, 1),
        endDate: DateTime(2027, 12, 31),
        batchMapping: {batchId: 'Science A (Class 10)'},
      );

      // New session is active, old one is not.
      final sessions = await service.all();
      expect(sessions.firstWhere((s) => s.id == next.id).isActive, isTrue);
      expect(sessions.firstWhere((s) => s.id == old.id).isActive, isFalse);

      // Both students carried, in a new batch.
      final newBatch = (await db.select(db.batches).get())
          .firstWhere((x) => x.sessionId == next.id);
      expect(newBatch.name, 'Science A (Class 10)');
      expect(newBatch.monthlyFee, 2500, reason: 'fee carried over');

      final roster = await students.watchBatchRoster(newBatch.id).first;
      expect(roster.map((s) => s.id).toSet(), {a.id, b.id});

      // Last year is exactly as it was — this is the property that keeps old
      // receipts verifiable.
      final oldEnrollments = await (db.select(db.enrollments)
            ..where((t) => t.sessionId.equals(sessionId)))
          .get();
      expect(oldEnrollments, hasLength(2));
      expect(oldEnrollments.every((e) => e.isActive), isTrue);
      expect(
        (await db.select(db.invoices).get()).every((i) => i.sessionId == sessionId),
        isTrue,
      );
    });

    test('a batch left out of the mapping is not carried', () async {
      await admit('Rahim');
      final service = SessionService(db: db, deviceId: device);
      final old = (await service.all()).single;

      final next = await service.rollOver(
        from: old,
        newName: '2027',
        startDate: DateTime(2027, 1, 1),
        endDate: DateTime(2027, 12, 31),
        batchMapping: const {},
      );

      expect(
        (await db.select(db.batches).get()).where((b) => b.sessionId == next.id),
        isEmpty,
      );
    });
  });

  group('student records', () {
    test('editing keeps the searchable phone in step', () async {
      final student = await admit('Rahim', phone: '01712345678');
      await students.update(student, guardianPhone: '+8801999888777');

      expect(await students.search('01999888777'), hasLength(1));
      expect(await students.search('01712345678'), isEmpty);
    });

    test('a transfer closes the old enrolment rather than rewriting it',
        () async {
      final student = await admit('Rahim');
      final other = await master.addBatch(
        sessionId: sessionId,
        classId: classId,
        name: 'Science B',
        monthlyFee: 2500,
      );

      await students.transferBatch(
        student: student,
        toBatchId: other.id,
        sessionId: sessionId,
        reason: 'Timing clash',
      );

      final enrollments = await (db.select(db.enrollments)
            ..where((t) => t.studentId.equals(student.id)))
          .get();
      expect(enrollments, hasLength(2));
      expect(enrollments.where((e) => e.isActive), hasLength(1));
      expect(enrollments.firstWhere((e) => e.isActive).batchId, other.id);
      expect(
        enrollments.firstWhere((e) => !e.isActive).leaveDate,
        isNotNull,
        reason: 'the old spell is closed, not deleted',
      );
    });

    test('dropping a student takes them off the roster but keeps the record',
        () async {
      final student = await admit('Rahim');
      await students.setStatus(student, StudentStatus.dropped,
          reason: 'Moved city');

      expect(await students.watchBatchRoster(batchId).first, isEmpty);
      expect(await db.select(db.students).get(), hasLength(1));
      final trail = await db.auditTrailFor('students', student.id);
      expect(trail.first.afterJson, contains('Moved city'));
    });

    test('siblings link both ways', () async {
      final a = await admit('Rahim');
      final b = await admit('Karima');
      await students.linkSiblings(a.id, b.id);

      expect((await students.siblingsOf(a.id)).single.id, b.id);
      expect((await students.siblingsOf(b.id)).single.id, a.id);

      // Linking twice must not duplicate.
      await students.linkSiblings(a.id, b.id);
      expect(await students.siblingsOf(a.id), hasLength(1));
    });

    test('the register can be narrowed to a batch', () async {
      await admit('Rahim');
      final other = await master.addBatch(
        sessionId: sessionId,
        classId: classId,
        name: 'Science B',
      );
      await students.admit(
          name: 'Karima', batchId: other.id, sessionId: sessionId);

      expect(await students.watchFiltered(batchId: batchId).first, hasLength(1));
      expect(await students.watchFiltered(classId: classId).first, hasLength(2));
    });
  });

  group('master data editing', () {
    test('rooms, periods and subjects can be corrected', () async {
      final room = await master.addRoom('Room 1', 30);
      await master.updateRoom(room, name: 'Main Hall', capacity: 60);
      expect((await master.watchRooms().first).single.capacity, 60);

      final subject =
          await master.addSubject(classId: classId, name: 'পদার্থবিজ্ঞান');
      await master.updateSubject(subject, weeklyClasses: 4);
      expect((await master.watchSubjects(classId).first).single.weeklyClasses, 4);

      final slot = await master.addTimeSlot(
          label: '4-5', startMinute: 960, endMinute: 1020);
      await master.updateTimeSlot(slot, label: '4:00 – 5:00 PM');
      expect((await master.watchTimeSlots().first).single.label,
          '4:00 – 5:00 PM');
    });

    test('archiving hides without destroying', () async {
      final room = await master.addRoom('Old Room', 20);
      await master.archiveRoom(room);

      expect(await master.watchRooms().first, isEmpty);
      expect(await db.select(db.rooms).get(), hasLength(1));
    });

    test('the centre profile can be corrected after setup', () async {
      final institution = await db.into(db.institutions).insertReturning(
            InstitutionsCompanion.insert(name: 'Typo Educare', deviceId: device),
          );
      await master.updateInstitution(institution,
          name: 'Advance Educare', phone: '01712345678');

      expect((await master.institution())!.name, 'Advance Educare');
    });
  });

  group('enquiries', () {
    test('follow-ups due today are listed', () async {
      final service = EnquiryService(db: db, deviceId: device);
      await service.record(
          name: 'Sadia', phone: '01711111111', followUpOn: DateTime(2026, 3, 1));
      await service.record(name: 'Later', followUpOn: DateTime(2030, 1, 1));

      final due = await service.dueForFollowUp(on: DateTime(2026, 3, 1));
      expect(due.map((e) => e.name), ['Sadia']);
    });

    test('the funnel counts what became of them', () async {
      final service = EnquiryService(db: db, deviceId: device);
      final a = await service.record(name: 'A');
      final b = await service.record(name: 'B');
      await service.record(name: 'C');

      await service.setStatus(a, EnquiryStatus.admitted);
      await service.setStatus(b, EnquiryStatus.lost);

      final funnel = await service.funnel(
          from: DateTime(2020), to: DateTime(2030));
      expect(funnel.total, 3);
      expect(funnel.admitted, 1);
      expect(funnel.lost, 1);
      expect(funnel.open, 1);
    });
  });

  group('reports', () {
    test('collections total what was taken, excluding cancellations', () async {
      final student = await admit('Rahim');
      await fees.collect(
        studentId: student.id,
        amount: 2500,
        method: PaymentMethod.cash,
        accountId: cashId,
        receivedOn: DateTime(2026, 3, 5),
      );
      final voided = (await fees.collect(
        studentId: student.id,
        amount: 900,
        method: PaymentMethod.cash,
        accountId: cashId,
        receivedOn: DateTime(2026, 3, 6),
      )).payment;
      await fees.cancelPayment(voided, reason: 'Duplicate');

      final report = await ReportsService(db: db, deviceId: device)
          .collections(from: DateTime(2026, 3), to: DateTime(2026, 4));

      expect(report.rows, hasLength(2));
      expect(report.totals.firstWhere((t) => t.$1 == 'Collected').$2, '৳2500');
      expect(report.totals.firstWhere((t) => t.$1 == 'Cancelled').$2, '৳900');
      expect(report.rows.any((r) => r.contains('CANCELLED')), isTrue);
    });

    test('low attendance lists who to ring', () async {
      final poor = await admit('Rarely');
      final good = await admit('Always');
      final attendance = AttendanceService(db: db, deviceId: device);

      for (final day in [
        DateTime(2026, 3, 2),
        DateTime(2026, 3, 3),
        DateTime(2026, 3, 4),
        DateTime(2026, 3, 5),
      ]) {
        final s = await attendance.openSession(batchId: batchId, on: day);
        await attendance.saveSession(sessionId: s.id, states: {
          poor.id: day.day == 2
              ? AttendanceState.present
              : AttendanceState.absent,
          good.id: AttendanceState.present,
        });
      }

      final report = await ReportsService(db: db, deviceId: device)
          .lowAttendance(from: DateTime(2026, 3), to: DateTime(2026, 4));

      expect(report.rows, hasLength(1));
      expect(report.rows.single.first, 'Rarely');
      expect(report.rows.single.last, '25%');
    });

    test('a report renders for printing', () async {
      final report = await ReportsService(db: db, deviceId: device)
          .outstanding();
      final html = ReportsService(db: db, deviceId: device)
          .toHtml(report, const DocumentEngine());

      expect(html, contains('Outstanding fees'));
      expect(html, contains('<table'));
    });
  });

  group('settings', () {
    test('fall back to a default and survive being changed', () async {
      final settings = AppSettings(db: db, deviceId: device);
      expect(await settings.readInt(AppSettings.autoLockMinutes), 3);

      await settings.write(AppSettings.autoLockMinutes, '15');
      expect(await settings.readInt(AppSettings.autoLockMinutes), 15);

      await settings.write(AppSettings.autoLockMinutes, '1');
      expect(await settings.readInt(AppSettings.autoLockMinutes), 1);
    });
  });

  group('xlsx import', () {
    /// Builds a real, minimal `.xlsx` so the reader is tested against the
    /// format rather than against a mock of it.
    File writeWorkbook(Directory dir, List<List<String>> rows) {
      final shared = <String>[];
      for (final row in rows) {
        for (final cell in row) {
          if (cell.isNotEmpty && !shared.contains(cell)) shared.add(cell);
        }
      }

      String colName(int index) {
        var n = index + 1;
        var name = '';
        while (n > 0) {
          final rem = (n - 1) % 26;
          name = String.fromCharCode(65 + rem) + name;
          n = (n - 1) ~/ 26;
        }
        return name;
      }

      final sheet = StringBuffer(
        '<?xml version="1.0"?><worksheet '
        'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetData>',
      );
      for (var r = 0; r < rows.length; r++) {
        sheet.write('<row r="${r + 1}">');
        for (var c = 0; c < rows[r].length; c++) {
          final value = rows[r][c];
          if (value.isEmpty) continue;
          sheet.write('<c r="${colName(c)}${r + 1}" t="s">'
              '<v>${shared.indexOf(value)}</v></c>');
        }
        sheet.write('</row>');
      }
      sheet.write('</sheetData></worksheet>');

      final strings = StringBuffer(
        '<?xml version="1.0"?><sst '
        'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
      );
      for (final value in shared) {
        strings.write('<si><t>${const HtmlEscape().convert(value)}</t></si>');
      }
      strings.write('</sst>');

      final archive = Archive()
        ..add(ArchiveFile.string(
            'xl/worksheets/sheet1.xml', sheet.toString()))
        ..add(ArchiveFile.string('xl/sharedStrings.xml', strings.toString()));

      final file = File('${dir.path}/register.xlsx');
      file.writeAsBytesSync(ZipEncoder().encodeBytes(archive));
      return file;
    }

    test('reads a spreadsheet the same way it reads a CSV', () async {
      final dir = await Directory.systemTemp.createTemp('xlsx');
      addTearDown(() => dir.delete(recursive: true));

      final file = writeWorkbook(dir, [
        ['শিক্ষার্থীর নাম', 'পিতার নাম', 'মোবাইল'],
        ['রহিম আহমেদ', 'করিম আহমেদ', '01712345678'],
        ['Karima Begum', 'Karim Ahmed', '01799999999'],
      ]);

      final rows = await XlsxReader.read(file);
      expect(rows, hasLength(3));
      expect(rows.first, ['শিক্ষার্থীর নাম', 'পিতার নাম', 'মোবাইল']);
      expect(rows[1][0], 'রহিম আহমেদ');

      final preview =
          await const CsvImportService().preview(file: file, db: db);
      expect(preview.mapping[ImportField.name], 0);
      expect(preview.mapping[ImportField.guardianPhone], 2);
      expect(preview.importable, hasLength(2));

      await const CsvImportService().commit(
        db: db,
        preview: preview,
        batchId: batchId,
        sessionId: sessionId,
        deviceId: device,
        sourceName: 'register.xlsx',
      );
      expect(await db.select(db.students).get(), hasLength(2));
    });

    test('a gap mid-row does not shift the columns after it', () async {
      final dir = await Directory.systemTemp.createTemp('xlsx_gap');
      addTearDown(() => dir.delete(recursive: true));

      final file = writeWorkbook(dir, [
        ['Name', 'Guardian', 'Mobile'],
        ['Rahim', '', '01712345678'],
      ]);

      final rows = await XlsxReader.read(file);
      expect(rows[1], ['Rahim', '', '01712345678']);
    });
  });
}
