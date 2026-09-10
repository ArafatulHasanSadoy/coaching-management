import 'dart:io';

import 'package:coaching_ops/data/db/database.dart';
import 'package:coaching_ops/data/db/tables.dart';
import 'package:coaching_ops/data/defaults/curriculum_defaults.dart';
import 'package:coaching_ops/data/setup/setup_service.dart';
import 'package:coaching_ops/data/students/csv_import.dart';
import 'package:coaching_ops/data/students/students_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late Directory tmp;
  late String sessionId;
  late String batchId;

  setUp(() async {
    db = AppDatabase.memory();
    tmp = await Directory.systemTemp.createTemp('import_test');

    await const SetupService().apply(
      db: db,
      deviceId: 'device-a',
      plan: SetupPlan(
        centreName: 'Advance Educare',
        address: '',
        phone: '',
        sessionName: '2026',
        sessionStart: DateTime(2026, 1, 1),
        sessionEnd: DateTime(2026, 12, 31),
        selectedClasses: [defaultClasses[3]],
        banglaSubjectNames: true,
        includeDefaultRooms: true,
        includeDefaultTimeSlots: false,
      ),
    );

    sessionId = (await db.select(db.academicSessions).get()).single.id;
    final classId = (await db.select(db.classes).get()).single.id;
    final batch = await db.into(db.batches).insertReturning(
          BatchesCompanion.insert(
            sessionId: sessionId,
            classId: classId,
            name: 'Science A',
            status: BatchStatus.active,
            deviceId: 'device-a',
            monthlyFee: const Value(2500),
          ),
        );
    batchId = batch.id;
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<File> csv(String content, {String name = 'register.csv'}) async {
    final file = File('${tmp.path}/$name');
    await file.writeAsString(content);
    return file;
  }

  group('column mapping', () {
    test('maps the headers a real register uses', () async {
      final file = await csv(
        'SL,Student Name,Father\'s Name,Mobile No,School,Blood Group\n'
        '1,Rahim Ahmed,Karim Ahmed,01712345678,Ideal School,B+\n',
      );

      final preview = await const CsvImportService().preview(file: file, db: db);

      expect(preview.mapping[ImportField.code], 0);
      expect(preview.mapping[ImportField.name], 1);
      expect(preview.mapping[ImportField.guardianName], 2);
      expect(preview.mapping[ImportField.guardianPhone], 3);
      expect(preview.mapping[ImportField.school], 4);
      expect(preview.mapping[ImportField.bloodGroup], 5);
    });

    test('maps Bangla headers', () async {
      final file = await csv('নাম,অভিভাবক,মোবাইল\nরহিম আহমেদ,করিম আহমেদ,01712345678\n');
      final preview = await const CsvImportService().preview(file: file, db: db);

      expect(preview.mapping[ImportField.name], 0);
      expect(preview.mapping[ImportField.guardianName], 1);
      expect(preview.mapping[ImportField.guardianPhone], 2);
      expect(preview.rows.single.values[ImportField.name], 'রহিম আহমেদ');
    });

    test('keeps "phone" and "guardian phone" apart', () async {
      final file = await csv('Name,Student Phone,Guardian Phone\nA,01711111111,01722222222\n');
      final preview = await const CsvImportService().preview(file: file, db: db);

      expect(preview.mapping[ImportField.studentPhone], 1);
      expect(preview.mapping[ImportField.guardianPhone], 2);
    });

    test('survives a UTF-8 BOM from Excel', () async {
      final file = await csv('﻿Name,Mobile\nRahim,01712345678\n');
      final preview = await const CsvImportService().preview(file: file, db: db);
      expect(preview.mapping[ImportField.name], 0);
    });
  });

  group('validation', () {
    test('blocks rows with no name but keeps everything else', () async {
      final file = await csv(
        'Name,Mobile\n'
        'Rahim,01712345678\n'
        ',01722222222\n'
        'Karim,01733333333\n',
      );
      final preview = await const CsvImportService().preview(file: file, db: db);

      expect(preview.rows, hasLength(3));
      expect(preview.blockedCount, 1);
      expect(preview.importable.map((r) => r.name), ['Rahim', 'Karim']);
      expect(
        preview.rows[1].issues.single.message,
        contains('No name'),
      );
    });

    test('warns about unusable phone numbers without dropping the student',
        () async {
      final file = await csv('Name,Mobile\nRahim,not recorded\n');
      final preview = await const CsvImportService().preview(file: file, db: db);

      final row = preview.rows.single;
      expect(row.blocked, isFalse, reason: 'a bad phone must not lose a student');
      expect(row.issues.single.severity, IssueSeverity.warning);
      expect(row.issues.single.message, contains('not a mobile number'));
    });

    test('flags repeated guardian numbers as possible siblings', () async {
      final file = await csv(
        'Name,Mobile\nRahim,01712345678\nKarima,01712345678\n',
      );
      final preview = await const CsvImportService().preview(file: file, db: db);

      expect(preview.rows[1].issues.single.message, contains('line 2'));
      expect(preview.rows[1].blocked, isFalse);
    });

    test('notices a register that was already imported once', () async {
      final file = await csv('Name,Mobile\nRahim,01712345678\n');
      final first = await const CsvImportService().preview(file: file, db: db);
      await const CsvImportService().commit(
        db: db,
        preview: first,
        batchId: batchId,
        sessionId: sessionId,
        deviceId: 'device-a',
        sourceName: 'register.csv',
      );

      final second = await const CsvImportService().preview(file: file, db: db);
      expect(
        second.rows.single.issues.single.message,
        contains('already in the app'),
      );
    });
  });

  group('dates', () {
    test('reads day-first, the way a Bangladeshi register writes them', () {
      expect(CsvImportService.parseDate('03/04/2010'), DateTime(2010, 4, 3));
      expect(CsvImportService.parseDate('25-12-2009'), DateTime(2009, 12, 25));
      expect(CsvImportService.parseDate('2010-04-03'), DateTime(2010, 4, 3));
      expect(CsvImportService.parseDate('5.6.09'), DateTime(2009, 6, 5));
    });

    test('swaps when the first number cannot be a day', () {
      expect(CsvImportService.parseDate('2010/13/04'), isNull);
      expect(CsvImportService.parseDate('04/25/2010'), DateTime(2010, 4, 25));
    });

    test('gives up rather than guessing wildly', () {
      expect(CsvImportService.parseDate('sometime in 2010'), isNull);
      expect(CsvImportService.parseDate(''), isNull);
    });
  });

  group('commit', () {
    test('creates students enrolled in the batch, with codes', () async {
      final file = await csv(
        'Name,Father\'s Name,Mobile,DOB\n'
        'Rahim Ahmed,Karim Ahmed,+8801712345678,03/04/2010\n'
        'Karima Begum,Karim Ahmed,01712345678,15/09/2011\n',
      );
      final preview = await const CsvImportService().preview(file: file, db: db);
      final outcome = await const CsvImportService().commit(
        db: db,
        preview: preview,
        batchId: batchId,
        sessionId: sessionId,
        deviceId: 'device-a',
        sourceName: 'register.csv',
        now: DateTime(2026, 3, 1),
      );

      expect(outcome.imported, 2);
      expect(outcome.firstCode, '26-00001');
      expect(outcome.lastCode, '26-00002');

      final students = await db.select(db.students).get();
      expect(students, hasLength(2));

      final rahim = students.firstWhere((s) => s.name == 'Rahim Ahmed');
      expect(rahim.guardianName, 'Karim Ahmed');
      expect(rahim.guardianPhone, '+8801712345678', reason: 'keep what was written');
      expect(rahim.guardianPhoneNorm, '01712345678', reason: 'normalised for search');
      expect(rahim.dateOfBirth, DateTime(2010, 4, 3));

      final enrollments = await db.select(db.enrollments).get();
      expect(enrollments, hasLength(2));
      expect(enrollments.every((e) => e.batchId == batchId), isTrue);
    });

    test('keeps IDs the centre already uses', () async {
      final file = await csv('Student ID,Name\nAEC-99,Rahim\n,Karim\n');
      final preview = await const CsvImportService().preview(file: file, db: db);
      await const CsvImportService().commit(
        db: db,
        preview: preview,
        batchId: batchId,
        sessionId: sessionId,
        deviceId: 'device-a',
        sourceName: 'register.csv',
        now: DateTime(2026, 3, 1),
      );

      final codes = (await db.select(db.students).get()).map((s) => s.code);
      expect(codes, containsAll(['AEC-99', '26-00001']));
    });

    test('leaves one audit row, not one per student', () async {
      final file = await csv(
        'Name\n${List.generate(20, (i) => 'Student $i').join('\n')}\n',
      );
      final preview = await const CsvImportService().preview(file: file, db: db);
      await const CsvImportService().commit(
        db: db,
        preview: preview,
        batchId: batchId,
        sessionId: sessionId,
        deviceId: 'device-a',
        sourceName: 'register.csv',
      );

      final trail = await (db.select(db.auditLog)
            ..where((t) => t.action.equals('imported')))
          .get();
      expect(trail, hasLength(1));
      expect(trail.single.afterJson, contains('"count":20'));
    });
  });

  group('the gate: a real-sized register', () {
    test('300 students import in seconds, and are searchable after', () async {
      final buffer = StringBuffer("SL,Student Name,Father's Name,Mobile,School\n");
      for (var i = 1; i <= 300; i++) {
        final phone = '017${(10000000 + i).toString().padLeft(8, '0')}';
        buffer.writeln('$i,Student $i,Guardian $i,$phone,School ${i % 7}');
      }
      final file = await csv(buffer.toString(), name: 'big.csv');

      final watch = Stopwatch()..start();
      final preview = await const CsvImportService().preview(file: file, db: db);
      final parseMs = watch.elapsedMilliseconds;

      expect(preview.rows, hasLength(300));
      expect(preview.blockedCount, 0);

      watch.reset();
      final outcome = await const CsvImportService().commit(
        db: db,
        preview: preview,
        batchId: batchId,
        sessionId: sessionId,
        deviceId: 'device-a',
        sourceName: 'big.csv',
      );
      final commitMs = watch.elapsedMilliseconds;

      expect(outcome.imported, 300);
      expect(await db.select(db.students).get(), hasLength(300));
      expect(await db.select(db.enrollments).get(), hasLength(300));

      // The gate allows five minutes for the whole job including a human
      // checking the column mapping. The machine's share must be a rounding
      // error against that, or the mapping review has no room to breathe.
      expect(parseMs, lessThan(5000), reason: 'parse took ${parseMs}ms');
      expect(commitMs, lessThan(5000), reason: 'commit took ${commitMs}ms');

      // And the point of importing: they must be findable.
      final repo = StudentsRepository(db: db, deviceId: 'device-a');
      watch.reset();
      final byPhone = await repo.search('01710000042');
      final searchMs = watch.elapsedMilliseconds;
      expect(byPhone.single.name, 'Student 42');
      expect(searchMs, lessThan(500), reason: 'search took ${searchMs}ms');

      final byName = await repo.search('Student 4');
      expect(byName, isNotEmpty);

      // ignore: avoid_print
      print('300 students — parse ${parseMs}ms, commit ${commitMs}ms, '
          'phone lookup ${searchMs}ms');
    });
  });
}
