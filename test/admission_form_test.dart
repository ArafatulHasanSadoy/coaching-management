import 'package:coaching_ops/data/db/database.dart';
import 'package:coaching_ops/data/db/tables.dart';
import 'package:coaching_ops/data/finance/fee_service.dart';
import 'package:coaching_ops/data/repositories/master_data_repository.dart';
import 'package:coaching_ops/data/students/admission_form_service.dart';
import 'package:coaching_ops/data/students/students_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late AdmissionFormService form;
  late StudentsRepository students;
  late MasterDataRepository master;
  late FeeService fees;
  late String sessionId;
  late String batchId;

  const device = 'device-a';

  setUp(() async {
    db = AppDatabase.memory();
    form = AdmissionFormService(db: db, deviceId: device);
    students = StudentsRepository(db: db, deviceId: device);
    master = MasterDataRepository(db: db, deviceId: device);
    fees = FeeService(db: db, deviceId: device);

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
    final schoolClass = await master.addClass('Class 9');
    batchId = (await master.addBatch(
      sessionId: sessionId,
      classId: schoolClass.id,
      name: 'Science A',
      monthlyFee: 2500,
    ))
        .id;
    await fees.ensureDefaults();
  });

  tearDown(() => db.close());

  group('the form the centre designs', () {
    test('ships as a usable demo rather than a blank page', () async {
      await form.ensureDefaultForm();
      final fields = await form.fields();

      expect(fields, isNotEmpty);
      expect(fields.first.label, 'Student name');
      expect(fields.map((f) => f.fieldKey), contains(AdmissionFormService.keyMonthlyFee));
      expect(
        fields.firstWhere((f) => f.fieldKey == AdmissionFormService.keyMonthlyFee).isRequired,
        isTrue,
        reason: 'the fee is mandatory at admission',
      );
      expect(fields.every((f) => f.isBuiltIn), isTrue);
    });

    test('seeding twice does not duplicate the form', () async {
      await form.ensureDefaultForm();
      final first = (await form.fields()).length;
      await form.ensureDefaultForm();
      expect((await form.fields()).length, first);
    });

    test('the centre can add its own questions', () async {
      await form.ensureDefaultForm();
      final field = await form.addField(
        label: 'Which bus route?',
        type: FormFieldType.choice,
        options: ['Mirpur', 'Uttara', 'Walks'],
        required: true,
      );

      expect(field.isBuiltIn, isFalse);
      expect(field.fieldKey, 'which_bus_route');
      expect(
        (await form.fields()).last.label,
        'Which bus route?',
        reason: 'new fields go to the end of the form',
      );
    });

    test('two fields with the same label get distinct keys', () async {
      await form.addField(label: 'Note', type: FormFieldType.text);
      final second = await form.addField(label: 'Note', type: FormFieldType.text);
      expect(second.fieldKey, 'note_2');
    });

    test('renaming a label keeps the answers attached', () async {
      final field =
          await form.addField(label: 'Bus route', type: FormFieldType.text);
      final student = await students.admit(
        name: 'Rahim',
        batchId: batchId,
        sessionId: sessionId,
        monthlyFee: 2000,
        customFields: {field.id: 'Mirpur'},
      );

      await form.updateField(field, label: 'Which bus route?');

      final filled = await form.valuesFor(student.id);
      expect(filled.single.field.label, 'Which bus route?');
      expect(filled.single.value, 'Mirpur',
          reason: 'the key is stable, so the answer survives a rename');
    });

    test('a built-in field is hidden, never deleted', () async {
      await form.ensureDefaultForm();
      final blood = (await form.fields())
          .firstWhere((f) => f.fieldKey == AdmissionFormService.keyBloodGroup);

      await form.removeField(blood);

      expect(
        (await form.fields()).map((f) => f.fieldKey),
        isNot(contains(AdmissionFormService.keyBloodGroup)),
      );
      // The column still exists on the student record, so the row survives.
      expect(await db.select(db.admissionFields).get(), isNotEmpty);
    });

    test('a custom field can be removed outright', () async {
      final field =
          await form.addField(label: 'Temporary', type: FormFieldType.text);
      await form.removeField(field);
      expect(await form.fields(), isEmpty);
    });

    test('reordering sticks', () async {
      final a = await form.addField(label: 'A', type: FormFieldType.text);
      final b = await form.addField(label: 'B', type: FormFieldType.text);
      await form.reorder([b, a]);
      expect((await form.fields()).map((f) => f.label), ['B', 'A']);
    });
  });

  group("the student's own monthly fee", () {
    test('is stored at admission and billed instead of the batch fee', () async {
      // Batch says 2500; this student negotiated 1800.
      final student = await students.admit(
        name: 'Rahim',
        batchId: batchId,
        sessionId: sessionId,
        monthlyFee: 1800,
      );
      expect(student.monthlyFee, 1800);

      await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 3),
      );

      final invoice = (await db.select(db.invoices).get()).single;
      expect(invoice.grossAmount, 1800,
          reason: 'the student fee wins over the batch fee');
    });

    test('falls back to the batch fee when none was set', () async {
      await students.admit(
        name: 'Karima',
        batchId: batchId,
        sessionId: sessionId,
      );
      await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 3),
      );
      expect((await db.select(db.invoices).get()).single.grossAmount, 2500);
    });

    test('can be changed later, and the next invoice follows', () async {
      final student = await students.admit(
        name: 'Rahim',
        batchId: batchId,
        sessionId: sessionId,
        monthlyFee: 1800,
      );
      await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 3),
      );

      await students.update(student, monthlyFee: 2200);
      await fees.generateMonthlyInvoices(
        sessionId: sessionId,
        forMonth: DateTime(2026, 4),
      );

      final invoices = await db.select(db.invoices).get()
        ..sort((a, b) => a.periodKey.compareTo(b.periodKey));
      expect(invoices.map((i) => i.grossAmount), [1800, 2200],
          reason: 'March keeps what it was billed; April uses the new figure');
    });
  });
}
