import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
// DriftRemoteException is the only way to see the real error behind drift's
// background-isolate wrapper, and telling "wrong passphrase" apart from "no
// cipher support" is not optional here — the two have opposite remedies. The
// API is marked experimental, so if a drift upgrade removes it, AppDatabase.open
// is the single place that breaks and the fallback is to stop using
// createInBackground.
// ignore: experimental_member_use
import 'package:drift/remote.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../finance/allocation_rebuild.dart';
import 'tables.dart';

part 'database.g.dart';

/// Thrown when the database file exists but will not open with the key we hold.
///
/// Distinguished from a generic failure because the remedy is specific and the
/// user needs to hear it: restore from a backup. Silently recreating the
/// database here would destroy a coaching center's records.
class DatabaseLockedException implements Exception {
  const DatabaseLockedException(this.cause);
  final Object cause;

  @override
  String toString() =>
      'DatabaseLockedException: the database could not be decrypted with the '
      'key held on this device ($cause)';
}

/// Thrown when the bundled SQLite has no encryption support, meaning the build
/// is not using SQLite3MultipleCiphers and data would be written in plaintext.
class EncryptionUnavailableException implements Exception {
  @override
  String toString() =>
      'EncryptionUnavailableException: this build has no cipher support. '
      "Check that pubspec.yaml still sets hooks/user_defines/sqlite3/source to "
      "'sqlite3mc' — without it the database would be stored unencrypted.";
}

@DriftDatabase(
  tables: [
    Institutions,
    AcademicSessions,
    Classes,
    Subjects,
    Rooms,
    TimeSlots,
    Batches,
    Students,
    Enrollments,
    Staff,
    StaffSubjects,
    FeeHeads,
    Discounts,
    Invoices,
    InvoiceItems,
    Payments,
    PaymentAllocations,
    StudentCredits,
    ReceiptSeries,
    Accounts,
    LedgerEntries,
    ExpenseHeads,
    Expenses,
    SalaryPayments,
    DailyClosings,
    ClassSessions,
    AttendanceRecords,
    StaffAttendance,
    InventoryItems,
    StockTransactions,
    Chapters,
    RoutineVersions,
    RoutineEntries,
    StaffAvailability,
    SubjectRequirements,
    Questions,
    QuestionPapers,
    PaperSections,
    PaperQuestions,
    Enquiries,
    StudentLinks,
    PeriodLocks,
    PrintTemplates,
    PrintJobs,
    AdmissionFields,
    StudentFieldValues,
    StaffClasses,
    AppUsers,
    Settings,
    AuditLog,
    ChangeLog,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Opens an encrypted database at [file] using [encryptionKey].
  factory AppDatabase.encrypted({
    required File file,
    required String encryptionKey,
  }) =>
      AppDatabase(_openEncrypted(file: file, encryptionKey: encryptionKey));

  /// Opens an encrypted database and proves the connection works before
  /// handing it back.
  ///
  /// This is the entry point features should use rather than [AppDatabase
  /// .encrypted] directly. Drift runs the database on a background isolate and
  /// re-throws anything it raises wrapped in a [DriftRemoteException], so the
  /// specific failures a caller needs to distinguish — a wrong passphrase
  /// versus a build with no cipher support — would otherwise arrive
  /// indistinguishable from any other error. The lock screen depends on telling
  /// those apart: one means "try again", the other means "restore from backup".
  static Future<AppDatabase> open({
    required File file,
    required String encryptionKey,
  }) async {
    final db = AppDatabase.encrypted(file: file, encryptionKey: encryptionKey);
    try {
      await db.customSelect('SELECT 1').get();
      return db;
    } catch (error) {
      await db.close();
      final cause = error is DriftRemoteException ? error.remoteCause : error;
      if (cause is DatabaseLockedException) throw cause;
      if (cause is EncryptionUnavailableException) throw cause;
      rethrow;
    }
  }

  /// In-memory database for tests. Unencrypted by design: tests exercise schema
  /// and behaviour, and there is no file to protect.
  factory AppDatabase.memory() => AppDatabase(NativeDatabase.memory());

  @override
  int get schemaVersion => 10;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          // Ordered oldest-first: v4's tables carry foreign keys into v3's, so
          // running them out of order would build the schema backwards.

          // v2 adds the master data the setup wizard and routine engine need.
          if (from < 2) {
            await m.createTable(classes);
            await m.createTable(subjects);
            await m.createTable(rooms);
            await m.createTable(timeSlots);
            await m.createTable(batches);
          }

          // v3 adds students and their batch enrolments.
          if (from < 3) {
            await m.createTable(students);
            await m.createTable(enrollments);
            for (final index in [
              idxStudentsGuardianPhone,
              idxStudentsStudentPhone,
              idxStudentsCode,
              idxEnrollmentsStudent,
              idxEnrollmentsBatch,
            ]) {
              await m.createIndex(index);
            }
          }

          // v4 adds staff, fees, finance, attendance and inventory — the
          // commercial core. One migration because they interlock: payments
          // need accounts, salary needs staff, attendance needs sessions.
          if (from < 4) {
            for (final table in <TableInfo<Table, dynamic>>[
              staff,
              staffSubjects,
              feeHeads,
              discounts,
              invoices,
              invoiceItems,
              accounts,
              payments,
              receiptSeries,
              ledgerEntries,
              expenseHeads,
              expenses,
              salaryPayments,
              dailyClosings,
              classSessions,
              attendanceRecords,
              staffAttendance,
              inventoryItems,
              stockTransactions,
            ]) {
              await m.createTable(table);
            }
            for (final index in [
              idxInvoicesStudent,
              idxInvoicesPeriod,
              idxPaymentsReceipt,
              idxPaymentsStudent,
              idxLedgerAccount,
              idxLedgerDate,
              idxClassSessionsDate,
              idxClassSessionsBatch,
              idxAttendanceSession,
              idxAttendanceStudent,
              idxStockItem,
            ]) {
              await m.createIndex(index);
            }
          }

          // v5 completes the product: the routine engine, the question bank,
          // and the records the earlier stages left unbuilt.
          if (from < 5) {
            for (final table in <TableInfo<Table, dynamic>>[
              chapters,
              routineVersions,
              routineEntries,
              staffAvailability,
              subjectRequirements,
              questions,
              questionPapers,
              paperSections,
              paperQuestions,
              enquiries,
              studentLinks,
              periodLocks,
            ]) {
              await m.createTable(table);
            }
            for (final index in [idxRoutineVersion, idxQuestionsSubject]) {
              await m.createIndex(index);
            }
          }

          // v6 adds the print centre — the fixed forms a centre already prints
          // by hand, and the layouts the app fills in.
          if (from < 6) {
            await m.createTable(printTemplates);
            await m.createTable(printJobs);
          }

          // v7 answers the first round of owner feedback: a form the centre
          // designs, a fee that belongs to the student, teachers who hold more
          // than one rate, and an expense head that can say what it was.
          if (from < 7) {
            await m.createTable(admissionFields);
            await m.createTable(studentFieldValues);
            await m.createTable(staffClasses);
            await m.createIndex(idxFieldValuesStudent);

            // `createTable` in an earlier step builds the table from today's
            // definition, which already includes these columns — so adding
            // them again would fail with "duplicate column". Only alter tables
            // that genuinely predate this version: students arrived in v3,
            // staff and expenses in v4.
            if (from >= 3) {
              await m.addColumn(students, students.monthlyFee);
            }
            if (from >= 4) {
              await m.addColumn(staff, staff.hourlyRate);
              await m.addColumn(staff, staff.isTeacher);
              await m.addColumn(expenses, expenses.customHead);
            }
          }

          // v8 lets the register say whether a class was a routine class or an
          // extra sitting, which is what separates per-class from hourly pay.
          if (from < 8) {
            if (from >= 4) {
              await m.addColumn(classSessions, classSessions.kind);
              await m.addColumn(classSessions, classSessions.durationMinutes);
            }
          }

          // v9 records which invoices a payment actually settled. Before this,
          // a payment covering three months was attached to one of them and
          // the other two stayed unpaid — the centre's single most common
          // bookkeeping mistake.
          if (from < 9) {
            await m.createTable(paymentAllocations);
            await m.createTable(studentCredits);
            await m.createIndex(idxAllocationPayment);
            await m.createIndex(idxAllocationInvoice);

            // Existing payments predate allocations, and some of them carry
            // the very mistake v9 fixes. Re-apply every one through today's
            // waterfall rather than copying the old single-invoice link.
            await rebuildAllocations(this);
          }

          // v10 marks which allocations were made from advance. A database
          // that ran the pre-release v9 also carries allocations built by an
          // earlier, wrong backfill — it dropped payments taken before any
          // invoice existed — so those are recomputed from the payments
          // themselves. Nothing released ever ran that v9; this is repair,
          // not routine.
          if (from < 10) {
            if (from >= 9) {
              await m.addColumn(paymentAllocations, paymentAllocations.fromCredit);
              await customStatement('DELETE FROM payment_allocations');
              await customStatement('DELETE FROM student_credits');
              await rebuildAllocations(this);
            }
          }
        },
        beforeOpen: (details) async {
          // Foreign keys are off by default in SQLite. Without this a batch
          // could reference a deleted class and nothing would complain until a
          // report tried to render it.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  /// Records an auditable change and its sync-log counterpart in one atomic
  /// step, so an audit row can never exist without its oplog entry or vice
  /// versa.
  ///
  /// Callers pass the row state as maps; encoding is handled here so that no
  /// feature has to remember to serialise consistently.
  Future<void> recordChange({
    required String entity,
    required String entityId,
    required ChangeOp op,
    required String deviceId,
    Map<String, Object?>? before,
    Map<String, Object?>? after,
    String? userId,
    String action = '',
  }) async {
    final beforeJson = before == null ? null : jsonEncode(before);
    final afterJson = after == null ? null : jsonEncode(after);

    await transaction(() async {
      await into(auditLog).insert(
        AuditLogCompanion.insert(
          entity: entity,
          entityId: entityId,
          action: action.isEmpty ? op.name : action,
          deviceId: deviceId,
          beforeJson: Value(beforeJson),
          afterJson: Value(afterJson),
          userId: Value(userId),
        ),
      );
      await into(changeLog).insert(
        ChangeLogCompanion.insert(
          entity: entity,
          entityId: entityId,
          op: op,
          deviceId: deviceId,
          payload: Value(afterJson),
        ),
      );
    });
  }

  /// Rows the audit trail holds for one record, newest first.
  Future<List<AuditLogData>> auditTrailFor(String entity, String entityId) {
    return (select(auditLog)
          ..where((t) => t.entity.equals(entity) & t.entityId.equals(entityId))
          ..orderBy([(t) => OrderingTerm.desc(t.seq)]))
        .get();
  }
}

QueryExecutor _openEncrypted({
  required File file,
  required String encryptionKey,
}) {
  return LazyDatabase(() async {
    await file.parent.create(recursive: true);

    return NativeDatabase.createInBackground(
      file,
      setup: (raw) => _applyKey(raw, encryptionKey),
    );
  });
}

/// Applies the encryption key and proves it worked.
///
/// Both checks matter. The first catches a build that quietly dropped cipher
/// support, which would write plaintext student and financial records to disk.
/// The second catches a key mismatch, which must surface as a restore prompt
/// rather than as a corrupt-database error somewhere later.
void _applyKey(sqlite3.Database raw, String encryptionKey) {
  raw.execute("PRAGMA key = '${encryptionKey.replaceAll("'", "''")}';");

  if (raw.select('PRAGMA cipher;').isEmpty) {
    throw EncryptionUnavailableException();
  }

  try {
    // Touching sqlite_schema forces the key to be validated now; without a
    // read, a wrong key stays undetected until the first real query.
    raw.select('SELECT count(*) FROM sqlite_schema;');
  } on sqlite3.SqliteException catch (e) {
    throw DatabaseLockedException(e);
  }
}
