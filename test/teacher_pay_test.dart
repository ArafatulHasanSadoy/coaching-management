import 'package:coaching_ops/data/db/database.dart';
import 'package:coaching_ops/data/db/tables.dart';
import 'package:coaching_ops/data/finance/payroll_service.dart';
import 'package:coaching_ops/data/repositories/master_data_repository.dart';
import 'package:coaching_ops/data/staff/staff_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late StaffRepository staff;
  late PayrollService payroll;
  late MasterDataRepository master;
  late String batchId;

  const device = 'device-a';

  setUp(() async {
    db = AppDatabase.memory();
    staff = StaffRepository(db: db, deviceId: device);
    payroll = PayrollService(db: db, deviceId: device);
    master = MasterDataRepository(db: db, deviceId: device);

    final session = await db.into(db.academicSessions).insertReturning(
          AcademicSessionsCompanion.insert(
            name: '2026',
            startDate: DateTime(2026, 1, 1),
            endDate: DateTime(2026, 12, 31),
            deviceId: device,
            isActive: const Value(true),
          ),
        );
    final schoolClass = await master.addClass('Class 9');
    batchId = (await master.addBatch(
      sessionId: session.id,
      classId: schoolClass.id,
      name: 'Science A',
    ))
        .id;
  });

  tearDown(() => db.close());

  Future<void> session({
    required String staffId,
    required DateTime on,
    SessionKind kind = SessionKind.regular,
    int minutes = 60,
  }) =>
      db.into(db.classSessions).insert(
            ClassSessionsCompanion.insert(
              batchId: batchId,
              heldOn: on,
              state: SessionState.held,
              deviceId: device,
              staffId: Value(staffId),
              kind: Value(kind),
              durationMinutes: Value(minutes),
            ),
          );

  group('teachers and other staff are separate lists', () {
    test('a teacher does not appear among the office staff', () async {
      await staff.add(name: 'Mr Rahman', isTeacher: true);
      await staff.add(name: 'Accounts clerk', isTeacher: false, role: 'Accounts');

      expect((await staff.watchTeachers().first).single.name, 'Mr Rahman');
      expect((await staff.watchOtherStaff().first).single.name, 'Accounts clerk');
    });

    test('a role defaults sensibly for each kind', () async {
      final teacher = await staff.add(name: 'A', isTeacher: true);
      final clerk = await staff.add(name: 'B', isTeacher: false);
      expect(teacher.role, 'Teacher');
      expect(clerk.role, 'Staff');
    });
  });

  group('a teacher paid both ways', () {
    test('earns per class for routine classes and by the hour for extras',
        () async {
      final teacher = await staff.add(
        name: 'Mr Karim',
        isTeacher: true,
        payModel: PayModel.perClass,
        perClassRate: 400,
        hourlyRate: 600,
      );

      // Four routine classes...
      for (final day in [2, 4, 6, 9]) {
        await session(staffId: teacher.id, on: DateTime(2026, 3, day));
      }
      // ...and two extra sittings: 90 minutes and 30 minutes.
      await session(
          staffId: teacher.id,
          on: DateTime(2026, 3, 10),
          kind: SessionKind.extra,
          minutes: 90);
      await session(
          staffId: teacher.id,
          on: DateTime(2026, 3, 11),
          kind: SessionKind.extra,
          minutes: 30);

      final line = (await payroll.payrollFor(DateTime(2026, 3))).single;

      expect(line.classesTaught, 4);
      expect(line.extraMinutes, 120);
      expect(line.classPay, 1600, reason: '4 × 400');
      expect(line.hourlyPay, 1200, reason: '2 hours × 600');
      expect(line.gross, 2800, reason: 'the two add up, not one replacing the other');
    });

    test('extras alone still pay, with no routine classes', () async {
      final teacher = await staff.add(
        name: 'Visiting teacher',
        isTeacher: true,
        payModel: PayModel.hourly,
        hourlyRate: 800,
      );
      await session(
          staffId: teacher.id,
          on: DateTime(2026, 3, 5),
          kind: SessionKind.extra,
          minutes: 45);

      final line = (await payroll.payrollFor(DateTime(2026, 3))).single;
      expect(line.classPay, 0);
      expect(line.hourlyPay, 600, reason: '45 minutes at 800/hour');
    });

    test('a monthly salary ignores both counts', () async {
      final teacher = await staff.add(
        name: 'Ms Nabila',
        isTeacher: true,
        payModel: PayModel.monthly,
        monthlySalary: 20000,
        perClassRate: 400,
      );
      await session(staffId: teacher.id, on: DateTime(2026, 3, 2));

      final line = (await payroll.payrollFor(DateTime(2026, 3))).single;
      expect(line.gross, 20000);
      expect(line.classPay, 0);
    });

    test('classes in another month do not count', () async {
      final teacher = await staff.add(
        name: 'Mr Karim',
        isTeacher: true,
        payModel: PayModel.perClass,
        perClassRate: 400,
      );
      await session(staffId: teacher.id, on: DateTime(2026, 3, 30));
      await session(staffId: teacher.id, on: DateTime(2026, 4, 1));

      expect((await payroll.payrollFor(DateTime(2026, 3))).single.classPay, 400);
    });
  });

  group('teacher attendance, counted both ways', () {
    test('reports classes taken and hours taught side by side', () async {
      final teacher = await staff.add(name: 'Mr Karim', isTeacher: true);

      for (final day in [2, 4, 6]) {
        await session(staffId: teacher.id, on: DateTime(2026, 3, day));
      }
      await session(
          staffId: teacher.id,
          on: DateTime(2026, 3, 7),
          kind: SessionKind.extra,
          minutes: 210);

      await db.into(db.staffAttendance).insert(
            StaffAttendanceCompanion.insert(
              staffId: teacher.id,
              onDate: DateTime(2026, 3, 2),
              state: AttendanceState.present,
              deviceId: device,
            ),
          );
      await db.into(db.staffAttendance).insert(
            StaffAttendanceCompanion.insert(
              staffId: teacher.id,
              onDate: DateTime(2026, 3, 3),
              state: AttendanceState.absent,
              deviceId: device,
            ),
          );

      final row = (await staff.attendanceFor(DateTime(2026, 3))).single;

      expect(row.regularClasses, 3);
      expect(row.extraMinutes, 210);
      expect(row.extraHoursLabel, '3 h 30 m');
      expect(row.daysPresent, 1);
      expect(row.daysAbsent, 1);
    });

    test('shows a dash rather than zero hours when there were no extras',
        () async {
      final teacher = await staff.add(name: 'Mr Karim', isTeacher: true);
      await session(staffId: teacher.id, on: DateTime(2026, 3, 2));

      final row = (await staff.attendanceFor(DateTime(2026, 3))).single;
      expect(row.extraHoursLabel, '—');
    });

    test('office staff are not in the teaching list', () async {
      await staff.add(name: 'Accounts clerk', isTeacher: false);
      expect(await staff.attendanceFor(DateTime(2026, 3)), isEmpty);
    });
  });

  group('which classes a teacher takes', () {
    test('is recorded and editable', () async {
      final teacher = await staff.add(name: 'Mr Rahman', isTeacher: true);
      final nine = await master.addClass('Class 9');
      final ten = await master.addClass('Class 10');

      await staff.setClasses(teacher.id, [nine.id, ten.id]);
      expect((await staff.classesOf(teacher.id)).map((c) => c.name),
          ['Class 9', 'Class 10']);

      // Replacing the set removes what is no longer true.
      await staff.setClasses(teacher.id, [ten.id]);
      expect((await staff.classesOf(teacher.id)).single.name, 'Class 10');
    });

    test('the profile gathers classes, pay and history in one place', () async {
      final teacher = await staff.add(
        name: 'Mr Rahman',
        isTeacher: true,
        phone: '01712345678',
        payModel: PayModel.perClass,
        perClassRate: 400,
      );
      final nine = await master.addClass('Class 9');
      await staff.setClasses(teacher.id, [nine.id]);
      await session(staffId: teacher.id, on: DateTime.now());

      // A real account: the foreign key is there for a reason, and a made-up
      // id would only pass by disabling it.
      final account = await db.into(db.accounts).insertReturning(
            AccountsCompanion.insert(
              name: 'Cash',
              kind: AccountKind.cash,
              deviceId: device,
            ),
          );

      await db.into(db.salaryPayments).insert(
            SalaryPaymentsCompanion.insert(
              staffId: teacher.id,
              accountId: account.id,
              periodKey: '2026-02',
              grossAmount: 5000,
              netAmount: 5000,
              paidOn: DateTime(2026, 2, 28),
              deviceId: device,
            ),
          );

      final profile = await staff.profileOf(teacher);
      expect(profile.classes.single.name, 'Class 9');
      expect(profile.classesTaughtThisMonth, 1);
      expect(profile.paidToDate, 5000);
      expect(profile.recentPayments, hasLength(1));
    });
  });
}
