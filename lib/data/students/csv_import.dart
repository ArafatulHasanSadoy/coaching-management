import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:drift/drift.dart';

import '../../core/phone.dart';
import '../db/database.dart';
import '../db/tables.dart';
import 'student_code.dart';
import 'xlsx_reader.dart';

/// A field an imported column can be mapped onto.
enum ImportField {
  name('Student name', required: true),
  code('Student ID'),
  nameAlt('Name (other script)'),
  guardianName('Guardian name'),
  guardianRelation('Guardian relation'),
  guardianPhone('Guardian phone'),
  studentPhone('Student phone'),
  school('School / college'),
  address('Address'),
  bloodGroup('Blood group'),
  gender('Gender'),
  dateOfBirth('Date of birth'),
  admissionDate('Admission date'),
  referredBy('Referred by'),
  notes('Notes');

  const ImportField(this.label, {this.required = false});

  final String label;
  final bool required;

  /// Header spellings seen in real registers, English and Bangla.
  ///
  /// Matching is what makes the difference between an import that takes two
  /// minutes and one that takes twenty: a centre's own spreadsheet should map
  /// itself, leaving the owner to correct one or two columns rather than
  /// assign fifteen.
  List<String> get aliases => switch (this) {
        ImportField.name => ['name', 'student name', 'student', 'studentname', 'নাম', 'শিক্ষার্থীর নাম', 'ছাত্রের নাম'],
        ImportField.code => ['id', 'student id', 'code', 'roll', 'roll no', 'serial', 'sl', 'আইডি', 'রোল'],
        ImportField.nameAlt => ['name bangla', 'bangla name', 'name english', 'english name'],
        ImportField.guardianName => ['guardian', 'guardian name', 'parent', 'parent name', 'father', "father's name", 'mother', 'অভিভাবক', 'পিতার নাম'],
        ImportField.guardianRelation => ['relation', 'guardian relation', 'সম্পর্ক'],
        ImportField.guardianPhone => ['guardian phone', 'parent phone', 'guardian mobile', 'parent mobile', 'contact', 'contact no', 'phone', 'mobile', 'mobile no', 'phone no', 'মোবাইল', 'ফোন', 'যোগাযোগ'],
        ImportField.studentPhone => ['student phone', 'student mobile', 'own phone', 'personal phone'],
        ImportField.school => ['school', 'college', 'institution', 'school name', 'স্কুল', 'কলেজ', 'প্রতিষ্ঠান'],
        ImportField.address => ['address', 'location', 'ঠিকানা'],
        ImportField.bloodGroup => ['blood', 'blood group', 'রক্তের গ্রুপ'],
        ImportField.gender => ['gender', 'sex', 'লিঙ্গ'],
        ImportField.dateOfBirth => ['dob', 'date of birth', 'birth date', 'birthday', 'জন্ম তারিখ'],
        ImportField.admissionDate => ['admission date', 'admitted', 'joining date', 'join date', 'ভর্তির তারিখ'],
        ImportField.referredBy => ['referred by', 'reference', 'source', 'রেফারেন্স'],
        ImportField.notes => ['notes', 'note', 'remarks', 'comment', 'মন্তব্য'],
      };
}

/// How serious a problem with an imported row is.
enum IssueSeverity {
  /// The row cannot be imported.
  blocking,

  /// The row imports, but something was changed or is worth a look.
  warning,
}

class ImportIssue {
  const ImportIssue(this.severity, this.message);
  final IssueSeverity severity;
  final String message;
}

/// One parsed row, with whatever is wrong with it.
class ImportRow {
  ImportRow({
    required this.lineNumber,
    required this.values,
    required this.issues,
  });

  /// Line in the original file, so the owner can find it in their spreadsheet.
  final int lineNumber;
  final Map<ImportField, String> values;
  final List<ImportIssue> issues;

  bool get blocked =>
      issues.any((i) => i.severity == IssueSeverity.blocking);

  String get name => values[ImportField.name] ?? '';
}

/// The result of reading a file, before anything is written.
class ImportPreview {
  ImportPreview({
    required this.headers,
    required this.mapping,
    required this.rows,
  });

  final List<String> headers;

  /// Column index for each field the importer recognised.
  final Map<ImportField, int> mapping;
  final List<ImportRow> rows;

  Iterable<ImportRow> get importable => rows.where((r) => !r.blocked);
  int get blockedCount => rows.length - importable.length;
  int get warningCount => importable
      .where((r) => r.issues.isNotEmpty)
      .length;
}


/// What a completed import did.
class ImportOutcome {
  const ImportOutcome({
    required this.imported,
    required this.skipped,
    required this.firstCode,
    required this.lastCode,
  });

  final int imported;
  final int skipped;
  final String firstCode;
  final String lastCode;
}

/// Reads a centre's existing student register and turns it into records.
///
/// Without this, a centre with three hundred students has to type them in, and
/// almost none will. It is the difference between the app being adopted and
/// being abandoned in week one — which is why it ships in v1 rather than later.
class CsvImportService {
  const CsvImportService();

  /// Parses [file] and guesses which column is which.
  ///
  /// Nothing is written. The owner reviews and corrects the mapping first.
  Future<ImportPreview> preview({
    required File file,
    required AppDatabase db,
    Map<ImportField, int>? overrideMapping,
  }) async {
    // A centre that keeps its register in Excel should not have to learn what
    // CSV is before it can use the app.
    final table = file.path.toLowerCase().endsWith('.xlsx')
        ? await _readSpreadsheet(file)
        : await _readCsv(file);

    if (table.isEmpty) {
      return ImportPreview(headers: const [], mapping: const {}, rows: const []);
    }

    final headers = table.first.map((h) => h.toString().trim()).toList();
    final mapping = overrideMapping ?? _guessMapping(headers);

    // Existing phone numbers, so a re-import does not silently duplicate a
    // register the owner already loaded once.
    final existingPhones = <String>{
      for (final s in await db.select(db.students).get())
        if (s.guardianPhoneNorm.isNotEmpty) s.guardianPhoneNorm,
    };
    final seenInFile = <String, int>{};

    final rows = <ImportRow>[];
    for (var i = 1; i < table.length; i++) {
      final raw = table[i];
      if (raw.every((c) => c.toString().trim().isEmpty)) continue;

      final values = <ImportField, String>{};
      for (final entry in mapping.entries) {
        if (entry.value < raw.length) {
          values[entry.key] = raw[entry.value].toString().trim();
        }
      }

      rows.add(
        ImportRow(
          lineNumber: i + 1,
          values: values,
          issues: _validate(values, existingPhones, seenInFile, i + 1),
        ),
      );
    }

    return ImportPreview(headers: headers, mapping: mapping, rows: rows);
  }


  /// Writes the importable rows as students enrolled in [batchId].
  ///
  /// Everything happens in one transaction and one pair of batched inserts.
  /// Three hundred students inserted one statement at a time, each re-reading
  /// every existing code to work out the next one, turns a five-minute job into
  /// a coffee break — so codes are computed once here and handed out in
  /// sequence.
  Future<ImportOutcome> commit({
    required AppDatabase db,
    required ImportPreview preview,
    required String batchId,
    required String sessionId,
    required String deviceId,
    required String sourceName,
    DateTime? now,
  }) async {
    final when = now ?? DateTime.now();
    final rows = preview.importable.toList(growable: false);
    if (rows.isEmpty) {
      return const ImportOutcome(
        imported: 0,
        skipped: 0,
        firstCode: '',
        lastCode: '',
      );
    }

    return db.transaction(() async {
      final institution = await (db.select(db.institutions)
            ..where((t) => t.deletedAt.isNull())
            ..limit(1))
          .getSingleOrNull();
      final pattern = institution?.studentIdPattern ?? '{YY}-{#####}';
      final prefix = StudentCode.prefixFor(pattern, when);

      final existingCodes = await db.students.select().map((s) => s.code).get();
      var sequence = 0;
      for (final code in existingCodes) {
        final n = StudentCode.sequenceOf(code, prefix);
        if (n != null && n > sequence) sequence = n;
      }

      final studentRows = <StudentsCompanion>[];
      final enrollmentRows = <EnrollmentsCompanion>[];
      var firstCode = '';
      var lastCode = '';

      for (final row in rows) {
        final id = newId();
        final supplied = row.values[ImportField.code] ?? '';

        // A centre that already numbers its students keeps its own numbers;
        // an ID printed on a card or written in a ledger must not change
        // because the data moved into an app.
        final code = supplied.isNotEmpty
            ? supplied
            : StudentCode.render(
                pattern: pattern,
                when: when,
                sequence: ++sequence,
              );
        if (firstCode.isEmpty) firstCode = code;
        lastCode = code;

        String value(ImportField f) => row.values[f] ?? '';
        final guardianPhone = value(ImportField.guardianPhone);
        final studentPhone = value(ImportField.studentPhone);
        final admitted = parseDate(value(ImportField.admissionDate)) ?? when;

        studentRows.add(
          StudentsCompanion.insert(
            id: Value(id),
            code: code,
            name: value(ImportField.name),
            admissionDate: admitted,
            status: StudentStatus.active,
            deviceId: deviceId,
            nameAlt: Value(value(ImportField.nameAlt)),
            guardianName: Value(value(ImportField.guardianName)),
            guardianRelation: Value(value(ImportField.guardianRelation)),
            guardianPhone: Value(guardianPhone),
            guardianPhoneNorm: Value(Phone.normalize(guardianPhone)),
            studentPhone: Value(studentPhone),
            studentPhoneNorm: Value(Phone.normalize(studentPhone)),
            school: Value(value(ImportField.school)),
            address: Value(value(ImportField.address)),
            bloodGroup: Value(value(ImportField.bloodGroup)),
            referredBy: Value(value(ImportField.referredBy)),
            notes: Value(value(ImportField.notes)),
            gender: Value(parseGender(value(ImportField.gender))),
            dateOfBirth: Value(parseDate(value(ImportField.dateOfBirth))),
          ),
        );

        enrollmentRows.add(
          EnrollmentsCompanion.insert(
            studentId: id,
            batchId: batchId,
            sessionId: sessionId,
            joinDate: admitted,
            deviceId: deviceId,
          ),
        );
      }

      await db.batch((b) {
        b.insertAll(db.students, studentRows);
        b.insertAll(db.enrollments, enrollmentRows);
      });

      // One audit row for the import, not one per student. Three hundred
      // near-identical entries would bury everything else in the trail.
      await db.recordChange(
        entity: 'students',
        entityId: 'import:${when.millisecondsSinceEpoch}',
        op: ChangeOp.insert,
        deviceId: deviceId,
        action: 'imported',
        after: {
          'source': sourceName,
          'count': studentRows.length,
          'batchId': batchId,
          'firstCode': firstCode,
          'lastCode': lastCode,
        },
      );

      return ImportOutcome(
        imported: studentRows.length,
        skipped: preview.blockedCount,
        firstCode: firstCode,
        lastCode: lastCode,
      );
    });
  }


  Future<List<List<dynamic>>> _readCsv(File file) async {
    var text = await file.readAsString(encoding: utf8);

    // Excel writes a UTF-8 BOM, which would otherwise become part of the first
    // header and stop it matching any alias.
    if (text.startsWith('\uFEFF')) text = text.substring(1);

    // dynamicTyping off keeps everything a string: a phone number parsed as a
    // number loses its leading zero, and a student ID like 007 becomes 7.
    // autoDetect handles the semicolon-delimited files Excel produces in some
    // locales.
    return Csv(dynamicTyping: false).decode(text);
  }

  Future<List<List<dynamic>>> _readSpreadsheet(File file) =>
      XlsxReader.read(file);

  Map<ImportField, int> _guessMapping(List<String> headers) {
    final mapping = <ImportField, int>{};
    final taken = <int>{};

    // Exact alias matches first, so a file with both "phone" and "guardian
    // phone" assigns each to the right field rather than to whichever was
    // checked first.
    for (final pass in [true, false]) {
      for (final field in ImportField.values) {
        if (mapping.containsKey(field)) continue;
        for (var i = 0; i < headers.length; i++) {
          if (taken.contains(i)) continue;
          final header = headers[i].toLowerCase().trim();
          if (header.isEmpty) continue;
          final hit = pass
              ? field.aliases.contains(header)
              : field.aliases.any((a) => header.contains(a) || a.contains(header));
          if (hit) {
            mapping[field] = i;
            taken.add(i);
            break;
          }
        }
      }
    }
    return mapping;
  }

  List<ImportIssue> _validate(
    Map<ImportField, String> values,
    Set<String> existingPhones,
    Map<String, int> seenInFile,
    int lineNumber,
  ) {
    final issues = <ImportIssue>[];

    if ((values[ImportField.name] ?? '').isEmpty) {
      issues.add(const ImportIssue(
        IssueSeverity.blocking,
        'No name — this row cannot become a student.',
      ));
    }

    final rawPhone = values[ImportField.guardianPhone] ?? '';
    if (rawPhone.isNotEmpty) {
      final norm = Phone.normalize(rawPhone);
      if (norm.isEmpty) {
        // Kept rather than rejected: registers hold landlines and notes, and
        // losing the student over an odd phone number would be worse.
        issues.add(ImportIssue(
          IssueSeverity.warning,
          '"$rawPhone" is not a mobile number — imported as written, but '
          'searching by it will not work.',
        ));
      } else {
        if (existingPhones.contains(norm)) {
          issues.add(const ImportIssue(
            IssueSeverity.warning,
            'A student with this guardian number is already in the app. This '
            'may be a sibling, or a row you have already imported.',
          ));
        }
        final earlier = seenInFile[norm];
        if (earlier != null) {
          issues.add(ImportIssue(
            IssueSeverity.warning,
            'Same guardian number as line $earlier — siblings, or a repeated row.',
          ));
        } else {
          seenInFile[norm] = lineNumber;
        }
      }
    }

    for (final (field, label) in [
      (ImportField.dateOfBirth, 'date of birth'),
      (ImportField.admissionDate, 'admission date'),
    ]) {
      final raw = values[field] ?? '';
      if (raw.isNotEmpty && parseDate(raw) == null) {
        issues.add(ImportIssue(
          IssueSeverity.warning,
          'Could not read "$raw" as a $label — left blank.',
        ));
      }
    }

    return issues;
  }

  /// Parses the date formats a Bangladeshi register actually uses.
  ///
  /// Day-first is assumed for ambiguous values, because `03/04/2010` in this
  /// context means 3 April far more often than 4 March.
  static DateTime? parseDate(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final iso = DateTime.tryParse(text);
    if (iso != null) return iso;

    final match =
        RegExp(r'^(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2,4})$').firstMatch(text);
    if (match == null) return null;

    var day = int.parse(match.group(1)!);
    var month = int.parse(match.group(2)!);
    var year = int.parse(match.group(3)!);

    // An unambiguous month in the first position means the file is month-first.
    if (day > 12 && month <= 12) {
      // already day-first
    } else if (month > 12 && day <= 12) {
      final swap = day;
      day = month;
      month = swap;
    }
    if (year < 100) year += year > 50 ? 1900 : 2000;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;

    return DateTime(year, month, day);
  }

  static Gender? parseGender(String raw) => switch (raw.trim().toLowerCase()) {
        'm' || 'male' || 'boy' || 'ছেলে' || 'পুরুষ' => Gender.male,
        'f' || 'female' || 'girl' || 'মেয়ে' || 'মহিলা' => Gender.female,
        '' => null,
        _ => Gender.other,
      };
}
