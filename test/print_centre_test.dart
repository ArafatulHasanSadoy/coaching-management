import 'dart:io';

import 'package:coaching_ops/data/db/database.dart';
import 'package:coaching_ops/data/db/tables.dart';
import 'package:coaching_ops/data/documents/document_engine.dart';
import 'package:coaching_ops/data/printing/id_card_document.dart';
import 'package:coaching_ops/data/printing/print_centre_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late PrintCentreService service;
  late Directory media;

  const device = 'device-a';

  setUp(() async {
    db = AppDatabase.memory();
    service = PrintCentreService(db: db, deviceId: device);
    media = await Directory.systemTemp.createTemp('print_centre');
  });

  tearDown(() async {
    await db.close();
    await media.delete(recursive: true);
  });

  Future<PrintTemplate> template({
    required PrintCadence cadence,
    String days = '',
    DateTime? lastPrinted,
    String name = 'Diary page',
  }) =>
      db.into(db.printTemplates).insertReturning(
            PrintTemplatesCompanion.insert(
              name: name,
              kind: TemplateKind.fixedFile,
              cadence: cadence,
              deviceId: device,
              cadenceDays: Value(days),
              lastPrintedAt: Value(lastPrinted),
            ),
          );

  group('uploaded forms', () {
    test('the file is copied into the app, not just pointed at', () async {
      final source = File('${media.path}/diary.pdf');
      await source.writeAsBytes(List<int>.filled(64, 1));

      final row = await service.addFixedFile(
        name: 'Diary page',
        source: source,
        mediaDir: media,
        cadence: PrintCadence.monthlyOnDays,
        days: [1, 16],
      );

      expect(row.filePath, isNotNull);
      expect(row.filePath, isNot(source.path));
      expect(File(row.filePath!).existsSync(), isTrue);

      // The original going away must not break the template — an owner tidying
      // their downloads is not an unusual event.
      await source.delete();
      expect(File(row.filePath!).existsSync(), isTrue);
    });
  });

  group('the fortnightly diary page', () {
    // The case from the original brief: printed on the 1st and the 16th.
    test('is due on the 16th if it has not been printed since', () async {
      await template(
        cadence: PrintCadence.monthlyOnDays,
        days: '1,16',
        lastPrinted: DateTime(2026, 9, 1),
      );

      final due = await service.dueNow(on: DateTime(2026, 9, 16));
      expect(due, hasLength(1));
      expect(due.single.reason, 'Due today');
    });

    test('is not due again once printed', () async {
      await template(
        cadence: PrintCadence.monthlyOnDays,
        days: '1,16',
        lastPrinted: DateTime(2026, 9, 16, 9),
      );
      expect(await service.dueNow(on: DateTime(2026, 9, 16, 14)), isEmpty);
    });

    test('says how overdue it is', () async {
      await template(
        cadence: PrintCadence.monthlyOnDays,
        days: '1,16',
        lastPrinted: DateTime(2026, 9, 1),
      );
      final due = await service.dueNow(on: DateTime(2026, 9, 20));
      expect(due.single.reason, 'Was due 4 days ago');
    });

    test('a never-printed template is due from its first scheduled day',
        () async {
      await template(cadence: PrintCadence.monthlyOnDays, days: '1,16');
      expect(await service.dueNow(on: DateTime(2026, 9, 5)), hasLength(1));
    });

    test('early in the month it looks back to last month', () async {
      // On 3 September with days 1 and 16, the last due date was 1 September.
      await template(
        cadence: PrintCadence.monthlyOnDays,
        days: '1,16',
        lastPrinted: DateTime(2026, 9, 1),
      );
      expect(await service.dueNow(on: DateTime(2026, 9, 3)), isEmpty);

      // But printed only in August, it is overdue.
      await db.update(db.printTemplates).write(
            PrintTemplatesCompanion(lastPrintedAt: Value(DateTime(2026, 8, 16))),
          );
      expect(await service.dueNow(on: DateTime(2026, 9, 3)), hasLength(1));
    });

    test('a day-30 schedule still works in February', () async {
      await template(
        cadence: PrintCadence.monthlyOnDays,
        days: '30',
        lastPrinted: DateTime(2026, 1, 30),
      );
      // On 5 March, the last due date was 28 February — the month's last day,
      // not a date that does not exist.
      final due = await service.dueNow(on: DateTime(2026, 3, 5));
      expect(due, hasLength(1));
    });

    test('on-demand templates never nag', () async {
      await template(cadence: PrintCadence.onDemand);
      expect(await service.dueNow(on: DateTime(2026, 9, 16)), isEmpty);
    });

    test('weekly is due from the start of the week', () async {
      await template(
        cadence: PrintCadence.weekly,
        lastPrinted: DateTime(2026, 9, 5), // a Saturday
      );
      // Still the same week on the Monday.
      expect(await service.dueNow(on: DateTime(2026, 9, 7)), isEmpty);
      // New week by the following Saturday.
      expect(await service.dueNow(on: DateTime(2026, 9, 12)), hasLength(1));
    });
  });

  group('printing history', () {
    test('recording a print clears the reminder and leaves a trail', () async {
      final row = await template(
        cadence: PrintCadence.monthlyOnDays,
        days: '1,16',
      );
      expect(await service.dueNow(on: DateTime(2026, 9, 16)), hasLength(1));

      await service.recordPrinted(row,
          copies: 40, by: 'Reception', at: DateTime(2026, 9, 16, 10));

      expect(await service.dueNow(on: DateTime(2026, 9, 16, 11)), isEmpty);

      final history = await service.history();
      expect(history.single.copies, 40);
      expect(history.single.title, 'Diary page');
    });
  });

  group('ID cards', () {
    test('lay out several to a page, with what a card needs', () {
      final students = [
        for (var i = 0; i < 3; i++)
          Student(
            id: 's$i',
            code: 'AEC-26-0000$i',
            name: 'Student $i',
            nameAlt: '',
            photoPath: null,
            dateOfBirth: null,
            gender: null,
            school: '',
            studentPhone: '',
            studentPhoneNorm: '',
            guardianName: '',
            guardianRelation: '',
            guardianPhone: '0171234567$i',
            guardianPhoneNorm: '',
            address: '',
            bloodGroup: 'B+',
            admissionDate: DateTime(2026),
            status: StudentStatus.active,
            monthlyFee: 0,
            referredBy: '',
            notes: '',
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
            deletedAt: null,
            deviceId: device,
          ),
      ];

      final html = IdCardDocument(engine: const DocumentEngine()).build(
        students: students,
        centreName: 'অ্যাডভান্স এডুকেয়ার',
        centrePhone: '01712345678',
        batchNames: const {'s0': 'Science A'},
      );

      expect(html, contains('অ্যাডভান্স এডুকেয়ার'));
      expect(html, contains('AEC-26-00000'));
      expect(html, contains('Science A'));
      expect(html, contains('B+'));
      expect('class="card"'.allMatches(html).length, 3);
      expect(html, contains('break-inside: avoid'));
    });
  });
}
