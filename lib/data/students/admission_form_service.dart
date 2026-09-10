import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';

/// A field on the form, paired with the value a student gave for it.
class FilledField {
  const FilledField({required this.field, required this.value});
  final AdmissionField field;
  final String value;

  List<String> get options {
    try {
      final raw = jsonDecode(field.optionsJson);
      return raw is List ? raw.map((o) => '$o').toList() : const [];
    } catch (_) {
      return const [];
    }
  }
}

/// The centre's own admission form.
///
/// Built before anyone is admitted, and then it *is* the form. Every centre
/// asks for something the next one does not — which bus route, whether a
/// sibling already attends, madrasah background — and a fixed set of columns
/// would leave each of them keeping a paper form alongside the app.
///
/// Fields come in two kinds. **Built-in** ones map onto real columns of the
/// student record, so name and phone stay searchable and the fee stays
/// billable; they can be relabelled and reordered but not deleted. **Custom**
/// ones are stored as answers and are the centre's own.
class AdmissionFormService {
  const AdmissionFormService({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  /// Keys of the fields that write to real columns.
  static const keyName = 'name';
  static const keyGuardianName = 'guardian_name';
  static const keyGuardianPhone = 'guardian_phone';
  static const keyMonthlyFee = 'monthly_fee';
  static const keyStudentPhone = 'student_phone';
  static const keySchool = 'school';
  static const keyAddress = 'address';
  static const keyBloodGroup = 'blood_group';
  static const keyDateOfBirth = 'date_of_birth';
  static const keyGender = 'gender';

  static const builtInKeys = {
    keyName,
    keyGuardianName,
    keyGuardianPhone,
    keyMonthlyFee,
    keyStudentPhone,
    keySchool,
    keyAddress,
    keyBloodGroup,
    keyDateOfBirth,
    keyGender,
  };

  /// The form a centre starts with.
  ///
  /// A demo rather than a blank page: an owner asked to design a form from
  /// nothing will design a worse one than the one they already use, and most
  /// will simply not bother.
  static const _demoForm = <({String key, String label, FormFieldType type, bool required})>[
    (key: keyName, label: 'Student name', type: FormFieldType.text, required: true),
    (key: keyGuardianName, label: "Guardian's name", type: FormFieldType.text, required: false),
    (key: keyGuardianPhone, label: "Guardian's phone", type: FormFieldType.phone, required: true),
    (key: keyMonthlyFee, label: 'Monthly fee', type: FormFieldType.number, required: true),
    (key: keyStudentPhone, label: "Student's phone", type: FormFieldType.phone, required: false),
    (key: keySchool, label: 'School / college', type: FormFieldType.text, required: false),
    (key: keyDateOfBirth, label: 'Date of birth', type: FormFieldType.date, required: false),
    (key: keyGender, label: 'Gender', type: FormFieldType.choice, required: false),
    (key: keyBloodGroup, label: 'Blood group', type: FormFieldType.text, required: false),
    (key: keyAddress, label: 'Address', type: FormFieldType.longText, required: false),
  ];

  /// Creates the demo form the first time. Safe to call repeatedly.
  Future<void> ensureDefaultForm() async {
    final existing = await db.select(db.admissionFields).get();
    if (existing.isNotEmpty) return;

    await db.transaction(() async {
      for (var i = 0; i < _demoForm.length; i++) {
        final field = _demoForm[i];
        await db.into(db.admissionFields).insert(
              AdmissionFieldsCompanion.insert(
                label: field.label,
                fieldKey: field.key,
                type: field.type,
                deviceId: deviceId,
                isRequired: Value(field.required),
                isBuiltIn: const Value(true),
                sortOrder: Value(i),
                optionsJson: Value(
                  field.key == keyGender
                      ? '["Male","Female","Other"]'
                      : '[]',
                ),
              ),
            );
      }
    });
  }

  Stream<List<AdmissionField>> watchFields() => (db.select(db.admissionFields)
        ..where((t) => t.deletedAt.isNull() & t.isActive.equals(true))
        ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
      .watch();

  Future<List<AdmissionField>> fields() => (db.select(db.admissionFields)
        ..where((t) => t.deletedAt.isNull() & t.isActive.equals(true))
        ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
      .get();

  Future<AdmissionField> addField({
    required String label,
    required FormFieldType type,
    bool required = false,
    List<String> options = const [],
    String hint = '',
  }) async {
    final existing = await fields();
    final row = await db.into(db.admissionFields).insertReturning(
          AdmissionFieldsCompanion.insert(
            label: label.trim(),
            // Derived from the label but kept stable afterwards, so renaming a
            // label never orphans the answers already collected under it.
            fieldKey: _keyFrom(label, existing.map((f) => f.fieldKey).toSet()),
            type: type,
            deviceId: deviceId,
            isRequired: Value(required),
            optionsJson: Value(jsonEncode(options)),
            hint: Value(hint),
            sortOrder: Value(existing.length),
          ),
        );

    await db.recordChange(
      entity: 'admission_fields',
      entityId: row.id,
      op: ChangeOp.insert,
      deviceId: deviceId,
      action: 'field_added',
      after: {'label': label, 'type': type.name},
    );
    return row;
  }

  Future<void> updateField(
    AdmissionField field, {
    String? label,
    bool? required,
    List<String>? options,
    String? hint,
  }) =>
      (db.update(db.admissionFields)..where((t) => t.id.equals(field.id))).write(
        AdmissionFieldsCompanion(
          label: Value(label ?? field.label),
          isRequired: Value(required ?? field.isRequired),
          optionsJson: Value(
            options == null ? field.optionsJson : jsonEncode(options),
          ),
          hint: Value(hint ?? field.hint),
          updatedAt: Value(DateTime.now()),
        ),
      );

  /// Removes a field the centre added.
  ///
  /// Built-in fields are only hidden, never removed — the student record still
  /// has that column and something has to fill it.
  Future<void> removeField(AdmissionField field) async {
    if (field.isBuiltIn) {
      await (db.update(db.admissionFields)..where((t) => t.id.equals(field.id)))
          .write(
        AdmissionFieldsCompanion(
          isActive: const Value(false),
          updatedAt: Value(DateTime.now()),
        ),
      );
      return;
    }
    await (db.update(db.admissionFields)..where((t) => t.id.equals(field.id)))
        .write(
      AdmissionFieldsCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> reorder(List<AdmissionField> ordered) async {
    await db.transaction(() async {
      for (var i = 0; i < ordered.length; i++) {
        await (db.update(db.admissionFields)
              ..where((t) => t.id.equals(ordered[i].id)))
            .write(AdmissionFieldsCompanion(sortOrder: Value(i)));
      }
    });
  }

  /// Stores the answers to custom fields for one student.
  Future<void> saveValues({
    required String studentId,
    required Map<String, String> byFieldId,
  }) async {
    await db.transaction(() async {
      await (db.delete(db.studentFieldValues)
            ..where((t) => t.studentId.equals(studentId)))
          .go();

      await db.batch((b) {
        b.insertAll(db.studentFieldValues, [
          for (final entry in byFieldId.entries)
            if (entry.value.trim().isNotEmpty)
              StudentFieldValuesCompanion.insert(
                studentId: studentId,
                fieldId: entry.key,
                deviceId: deviceId,
                value: Value(entry.value.trim()),
              ),
        ]);
      });
    });
  }

  /// The centre's own fields and what this student answered.
  Future<List<FilledField>> valuesFor(String studentId) async {
    final all = await fields();
    final custom = all.where((f) => !f.isBuiltIn).toList();
    if (custom.isEmpty) return const [];

    final stored = await (db.select(db.studentFieldValues)
          ..where((t) => t.studentId.equals(studentId) & t.deletedAt.isNull()))
        .get();
    final byField = {for (final v in stored) v.fieldId: v.value};

    return [
      for (final field in custom)
        FilledField(field: field, value: byField[field.id] ?? ''),
    ];
  }

  static String _keyFrom(String label, Set<String> taken) {
    final base = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final root = base.isEmpty ? 'field' : base;

    var key = root;
    var n = 2;
    while (taken.contains(key)) {
      key = '${root}_$n';
      n++;
    }
    return key;
  }
}
