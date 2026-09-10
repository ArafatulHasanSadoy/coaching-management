import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Generates the UUID primary key used by every syncable table.
///
/// Public because drift's generated code lives in a separate part file and
/// cannot reach a private helper.
String newId() => _uuid.v4();

/// Roles gating what a signed-in user can see.
///
/// Two is deliberate: the receptionist who collects fees must not see profit
/// reports or teacher salaries, and adding that distinction later would mean
/// auditing every screen retroactively.
enum UserRole { owner, staff }

/// What a [ChangeLog] entry records.
enum ChangeOp { insert, update, softDelete }

/// Columns carried by every domain table.
///
/// None of this is used by v1 features. It exists from schema version 1 because
/// retrofitting it onto live customer data would be a migration rather than a
/// change:
///
///  * [id] is a UUID, not an autoincrementing int, so rows created independently
///    on two devices can never collide once sync exists.
///  * [updatedAt] plus the [ChangeLog] oplog are what a future sync reconciles on.
///  * [deletedAt] means nothing is ever hard-deleted. Required for money and
///    marks; applied everywhere so there is one rule rather than two.
///  * [deviceId] records which device authored a row, for sync conflict reporting.
mixin SyncableTable on Table {
  TextColumn get id => text().clientDefault(newId)();
  DateTimeColumn get createdAt => dateTime().clientDefault(DateTime.now)();
  DateTimeColumn get updatedAt => dateTime().clientDefault(DateTime.now)();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  TextColumn get deviceId => text().withLength(max: 64)();

  @override
  Set<Column> get primaryKey => {id};
}

/// The coaching center itself. Exactly one row.
///
/// Everything here is configurable rather than hardcoded, because this ships to
/// centers other than the pilot one.
class Institutions extends Table with SyncableTable {
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get address => text().withDefault(const Constant(''))();
  TextColumn get phone => text().withDefault(const Constant(''))();
  TextColumn get email => text().withDefault(const Constant(''))();
  TextColumn get logoPath => text().nullable()();

  /// Printed at the foot of every money receipt.
  TextColumn get receiptFooter => text().withDefault(const Constant(''))();

  /// Name printed above the signature line on receipts and certificates.
  TextColumn get signatureName => text().withDefault(const Constant(''))();

  /// Pattern for generated student IDs, e.g. `AEC-{YY}-{#####}`.
  TextColumn get studentIdPattern =>
      text().withDefault(const Constant('{YY}-{#####}'))();
}

/// An academic year. Keeps 2026's students, fees and attendance separate from
/// 2027's instead of accumulating into one undifferentiated pile.
class AcademicSessions extends Table with SyncableTable {
  TextColumn get name => text().withLength(min: 1, max: 100)();
  DateTimeColumn get startDate => dateTime()();
  DateTimeColumn get endDate => dateTime()();
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
}

/// A person who can unlock the app.
class AppUsers extends Table with SyncableTable {
  TextColumn get name => text().withLength(min: 1, max: 120)();
  TextColumn get role => textEnum<UserRole>()();

  /// PBKDF2 hash of the PIN, with its per-user salt. The PIN itself is never
  /// stored, and neither value is enough to unlock the database.
  TextColumn get pinHash => text()();
  TextColumn get pinSalt => text()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

/// Loose key/value application settings.
class Settings extends Table with SyncableTable {
  TextColumn get key => text().withLength(min: 1, max: 100).unique()();
  TextColumn get value => text().withDefault(const Constant(''))();
}

/// Append-only record of who changed what.
///
/// Deliberately does not use [SyncableTable]: an audit trail that can itself be
/// edited or soft-deleted is not an audit trail. Rows are inserted and never
/// touched again.
class AuditLog extends Table {
  IntColumn get seq => integer().autoIncrement()();
  TextColumn get entity => text().withLength(max: 60)();
  TextColumn get entityId => text().withLength(max: 60)();
  TextColumn get action => text().withLength(max: 30)();

  /// Row state before and after, as JSON. Null on insert/delete respectively.
  TextColumn get beforeJson => text().nullable()();
  TextColumn get afterJson => text().nullable()();
  TextColumn get userId => text().nullable()();
  TextColumn get deviceId => text().withLength(max: 64)();
  DateTimeColumn get at => dateTime().clientDefault(DateTime.now)();
}

/// Append-only operation log, the substrate a future multi-device sync replays.
///
/// Unused in v1 — written but never read. It exists now so that turning sync on
/// later is a feature rather than a data migration.
class ChangeLog extends Table {
  IntColumn get seq => integer().autoIncrement()();
  TextColumn get entity => text().withLength(max: 60)();
  TextColumn get entityId => text().withLength(max: 60)();
  TextColumn get op => textEnum<ChangeOp>()();
  TextColumn get payload => text().nullable()();
  TextColumn get deviceId => text().withLength(max: 64)();
  DateTimeColumn get at => dateTime().clientDefault(DateTime.now)();

  /// Null until a sync backend acknowledges the row.
  DateTimeColumn get syncedAt => dateTime().nullable()();
}

/// Where a batch is in its life.
enum BatchStatus { active, inactive, completed, archived }

/// A class or grade the centre teaches.
///
/// Free text rather than a fixed 6–12 enum: centres run "SSC 2027",
/// "HSC Science", "Admission — Engineering" alongside school grades, and a
/// product that cannot express what is written on their own whiteboard gets
/// abandoned in the first hour.
@DataClassName('SchoolClass')
class Classes extends Table with SyncableTable {
  TextColumn get name => text().withLength(min: 1, max: 100)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

/// A subject taught within a class.
class Subjects extends Table with SyncableTable {
  TextColumn get classId => text().references(Classes, #id)();
  TextColumn get name => text().withLength(min: 1, max: 100)();

  /// Short form for routine grids and question-paper headers, where the full
  /// name will not fit — "পদার্থ" for পদার্থবিজ্ঞান.
  TextColumn get shortName => text().withLength(max: 20).withDefault(const Constant(''))();

  /// Periods per week this subject needs. The routine solver treats it as a
  /// hard requirement, so it lives here rather than being invented later.
  IntColumn get weeklyClasses => integer().withDefault(const Constant(2))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

/// A physical room. Exists as a real entity because the routine engine needs to
/// know that two batches cannot occupy one room, and that a batch of 42 does not
/// fit in a room for 30.
class Rooms extends Table with SyncableTable {
  TextColumn get name => text().withLength(min: 1, max: 100)();
  IntColumn get capacity => integer().withDefault(const Constant(30))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

/// A teaching period in the centre's day.
///
/// Stored as minutes from midnight rather than as text, so the routine engine
/// can compare and detect overlap without parsing. Never hardcode 4–5, 5–6:
/// every centre sets its own hours, and shifts differ between weekdays and
/// Fridays.
class TimeSlots extends Table with SyncableTable {
  TextColumn get label => text().withLength(max: 40).withDefault(const Constant(''))();
  IntColumn get startMinute => integer()();
  IntColumn get endMinute => integer()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

/// A group of students taught together.
///
/// Money is stored as **whole Taka**, not paisa. Bangladeshi coaching fees are
/// always whole amounts and paisa has not circulated in decades, so minor units
/// would add a ×100 conversion at every call site to represent something nobody
/// uses. If that ever proves wrong, the migration is a single multiply.
@DataClassName('StudentBatch')
class Batches extends Table with SyncableTable {
  TextColumn get sessionId => text().references(AcademicSessions, #id)();
  TextColumn get classId => text().references(Classes, #id)();
  TextColumn get name => text().withLength(min: 1, max: 100)();

  /// Science / Commerce / Arts, where the centre streams by group.
  TextColumn get groupName => text().withLength(max: 60).withDefault(const Constant(''))();
  IntColumn get capacity => integer().withDefault(const Constant(30))();
  TextColumn get defaultRoomId => text().nullable().references(Rooms, #id)();

  /// Default monthly tuition in whole Taka. Per-student overrides come later.
  IntColumn get monthlyFee => integer().withDefault(const Constant(0))();
  TextColumn get status => textEnum<BatchStatus>()();
}

/// Where a student stands with the centre.
enum StudentStatus { active, inactive, dropped, completed }

enum Gender { male, female, other }

/// A student.
///
/// `guardianPhoneNorm` and `studentPhoneNorm` hold digits only, stripped of
/// +88, spaces and dashes. They are denormalised copies rather than computed on
/// read because the front desk's most frequent action by a wide margin is
/// looking someone up by the number a parent is calling from — and a prefix
/// match on an indexed column can use the index, where normalising inside the
/// query could not.
@DataClassName('Student')
@TableIndex(name: 'idx_students_guardian_phone', columns: {#guardianPhoneNorm})
@TableIndex(name: 'idx_students_student_phone', columns: {#studentPhoneNorm})
@TableIndex(name: 'idx_students_code', columns: {#code})
class Students extends Table with SyncableTable {
  /// Generated from the centre's own pattern, e.g. `AEC-26-00427`.
  TextColumn get code => text().withLength(max: 40)();

  /// The name used everywhere in the interface. May itself be Bangla — this is
  /// content, not chrome.
  TextColumn get name => text().withLength(min: 1, max: 150)();

  /// Optional second-script name, for centres that keep both.
  TextColumn get nameAlt => text().withLength(max: 150).withDefault(const Constant(''))();

  TextColumn get photoPath => text().nullable()();
  DateTimeColumn get dateOfBirth => dateTime().nullable()();
  TextColumn get gender => textEnum<Gender>().nullable()();

  /// The school or college the student attends outside the centre.
  TextColumn get school => text().withLength(max: 150).withDefault(const Constant(''))();

  TextColumn get studentPhone => text().withLength(max: 30).withDefault(const Constant(''))();
  TextColumn get studentPhoneNorm => text().withLength(max: 20).withDefault(const Constant(''))();
  TextColumn get guardianName => text().withLength(max: 150).withDefault(const Constant(''))();
  TextColumn get guardianRelation => text().withLength(max: 40).withDefault(const Constant(''))();
  TextColumn get guardianPhone => text().withLength(max: 30).withDefault(const Constant(''))();
  TextColumn get guardianPhoneNorm => text().withLength(max: 20).withDefault(const Constant(''))();

  TextColumn get address => text().withDefault(const Constant(''))();
  TextColumn get bloodGroup => text().withLength(max: 10).withDefault(const Constant(''))();
  DateTimeColumn get admissionDate => dateTime()();
  TextColumn get status => textEnum<StudentStatus>()();

  /// What this student pays each month, in whole Taka.
  ///
  /// Held per student rather than read from the batch: a batch fee is a
  /// starting point, but siblings, scholarships and negotiated rates mean the
  /// real figure differs person to person, and billing should use the real one.
  IntColumn get monthlyFee => integer().withDefault(const Constant(0))();

  /// How they heard about the centre, for the owner's own marketing sense.
  TextColumn get referredBy => text().withLength(max: 150).withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();
}

/// A student's membership of a batch within a session.
///
/// Separate from [Students] because a student moves between batches, and
/// because next year's enrolment must not overwrite this year's record — the
/// fees they paid and the classes they attended hang off it.
@TableIndex(name: 'idx_enrollments_student', columns: {#studentId})
@TableIndex(name: 'idx_enrollments_batch', columns: {#batchId})
class Enrollments extends Table with SyncableTable {
  TextColumn get studentId => text().references(Students, #id)();
  TextColumn get batchId => text().references(Batches, #id)();
  TextColumn get sessionId => text().references(AcademicSessions, #id)();
  DateTimeColumn get joinDate => dateTime()();
  DateTimeColumn get leaveDate => dateTime().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

// ===================== Stage 4 — staff =====================

enum PayModel { monthly, perClass, hourly }

/// A teacher or staff member.
@DataClassName('StaffMember')
class Staff extends Table with SyncableTable {
  TextColumn get name => text().withLength(min: 1, max: 150)();
  TextColumn get phone => text().withLength(max: 30).withDefault(const Constant(''))();
  TextColumn get phoneNorm => text().withLength(max: 20).withDefault(const Constant(''))();
  TextColumn get role => text().withLength(max: 60).withDefault(const Constant('Teacher'))();
  TextColumn get address => text().withDefault(const Constant(''))();
  DateTimeColumn get joinDate => dateTime()();

  /// How this person is paid. Per-class pay is computed from the class-taken
  /// register, which is why attendance for staff is not optional.
  TextColumn get payModel => textEnum<PayModel>()();
  IntColumn get monthlySalary => integer().withDefault(const Constant(0))();
  IntColumn get perClassRate => integer().withDefault(const Constant(0))();

  /// Some teachers are paid per class for regular batches and by the hour for
  /// extra sittings, so both rates live on the same person rather than the pay
  /// model being a single exclusive choice.
  IntColumn get hourlyRate => integer().withDefault(const Constant(0))();

  /// Separates teaching staff from the office. They appear in different lists
  /// and only teachers reach the routine builder.
  BoolColumn get isTeacher => boolean().withDefault(const Constant(true))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get notes => text().withDefault(const Constant(''))();
}

/// Which subjects a staff member can teach. Feeds the routine engine later.
class StaffSubjects extends Table with SyncableTable {
  TextColumn get staffId => text().references(Staff, #id)();
  TextColumn get subjectId => text().references(Subjects, #id)();
}

// ===================== Stage 5 — fees =====================

enum FeeKind { monthly, admission, exam, material, other }

enum InvoiceStatus { unpaid, partial, paid, waived }

enum PaymentMethod { cash, bkash, nagad, bank, other }

/// A kind of charge the centre raises.
class FeeHeads extends Table with SyncableTable {
  TextColumn get name => text().withLength(min: 1, max: 100)();
  TextColumn get kind => textEnum<FeeKind>()();
  IntColumn get defaultAmount => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// A per-student adjustment to what a fee head costs them.
///
/// Carries who approved it and why, because a discount nobody can account for
/// is how a centre's income quietly leaks.
class Discounts extends Table with SyncableTable {
  TextColumn get studentId => text().references(Students, #id)();
  TextColumn get feeHeadId => text().nullable().references(FeeHeads, #id)();

  /// Whole Taka off, applied per invoice line.
  IntColumn get amount => integer()();
  TextColumn get reason => text().withDefault(const Constant(''))();
  TextColumn get approvedBy => text().withDefault(const Constant(''))();
  DateTimeColumn get validFrom => dateTime().nullable()();
  DateTimeColumn get validTo => dateTime().nullable()();
}

/// A charge raised against a student for a billing period.
@TableIndex(name: 'idx_invoices_student', columns: {#studentId})
@TableIndex(name: 'idx_invoices_period', columns: {#periodKey})
class Invoices extends Table with SyncableTable {
  TextColumn get studentId => text().references(Students, #id)();
  TextColumn get sessionId => text().references(AcademicSessions, #id)();
  TextColumn get batchId => text().nullable().references(Batches, #id)();

  /// `2026-03` for a monthly invoice; free text for one-offs. Used to stop the
  /// same month being billed twice.
  TextColumn get periodKey => text().withLength(max: 20)();
  DateTimeColumn get issuedOn => dateTime()();
  DateTimeColumn get dueOn => dateTime().nullable()();

  IntColumn get grossAmount => integer().withDefault(const Constant(0))();
  IntColumn get discountAmount => integer().withDefault(const Constant(0))();

  /// gross - discount. Stored rather than computed so a historical invoice
  /// cannot change when a discount is edited later.
  IntColumn get netAmount => integer().withDefault(const Constant(0))();
  IntColumn get paidAmount => integer().withDefault(const Constant(0))();
  TextColumn get status => textEnum<InvoiceStatus>()();
  TextColumn get note => text().withDefault(const Constant(''))();
}

class InvoiceItems extends Table with SyncableTable {
  TextColumn get invoiceId => text().references(Invoices, #id)();
  TextColumn get feeHeadId => text().references(FeeHeads, #id)();
  TextColumn get label => text().withLength(max: 120)();
  IntColumn get amount => integer()();
  IntColumn get discount => integer().withDefault(const Constant(0))();
}

/// Money received. Immutable once written.
///
/// A cancellation sets [isCancelled] and writes a compensating ledger entry; it
/// never deletes the row and never reuses the receipt number. Gapless numbering
/// is what makes a receipt book auditable, and a missing number is exactly what
/// an auditor asks about.
@TableIndex(name: 'idx_payments_receipt', columns: {#receiptNo})
@TableIndex(name: 'idx_payments_student', columns: {#studentId})
class Payments extends Table with SyncableTable {
  TextColumn get receiptNo => text().withLength(max: 40)();
  TextColumn get studentId => text().references(Students, #id)();
  TextColumn get invoiceId => text().nullable().references(Invoices, #id)();
  IntColumn get amount => integer()();
  TextColumn get method => textEnum<PaymentMethod>()();
  TextColumn get accountId => text().references(Accounts, #id)();
  TextColumn get reference => text().withLength(max: 80).withDefault(const Constant(''))();
  DateTimeColumn get receivedOn => dateTime()();
  TextColumn get receivedBy => text().withDefault(const Constant(''))();
  TextColumn get forPeriod => text().withLength(max: 40).withDefault(const Constant(''))();
  BoolColumn get isCancelled => boolean().withDefault(const Constant(false))();
  TextColumn get cancelReason => text().withDefault(const Constant(''))();
  TextColumn get note => text().withDefault(const Constant(''))();
}

/// The receipt number counter. One row per prefix.
class ReceiptSeries extends Table with SyncableTable {
  TextColumn get prefix => text().withLength(max: 20).unique()();
  IntColumn get nextNumber => integer().withDefault(const Constant(1))();
  IntColumn get padding => integer().withDefault(const Constant(5))();
}

// ===================== Stage 6 — finance =====================

enum AccountKind { cash, bkash, nagad, bank, other }

enum LedgerKind { income, expense, transfer, adjustment }

/// A place money sits.
class Accounts extends Table with SyncableTable {
  TextColumn get name => text().withLength(min: 1, max: 80)();
  TextColumn get kind => textEnum<AccountKind>()();
  IntColumn get openingBalance => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// Every movement of money, append-only.
///
/// Nothing here is ever edited or deleted. A mistake is corrected by writing a
/// compensating entry that points back at the original through [reversesId], so
/// a balance is always the plain sum of its entries and the history of a
/// correction stays visible.
@TableIndex(name: 'idx_ledger_account', columns: {#accountId})
@TableIndex(name: 'idx_ledger_date', columns: {#occurredOn})
class LedgerEntries extends Table with SyncableTable {
  TextColumn get accountId => text().references(Accounts, #id)();

  /// Positive money in, negative money out.
  IntColumn get amount => integer()();
  TextColumn get kind => textEnum<LedgerKind>()();
  DateTimeColumn get occurredOn => dateTime()();
  TextColumn get description => text().withDefault(const Constant(''))();

  /// What caused this — `payments`, `expenses`, `salary_payments`.
  TextColumn get sourceEntity => text().withLength(max: 40).withDefault(const Constant(''))();
  TextColumn get sourceId => text().withLength(max: 60).withDefault(const Constant(''))();

  /// Set when this entry undoes an earlier one.
  TextColumn get reversesId => text().nullable()();
}

class ExpenseHeads extends Table with SyncableTable {
  TextColumn get name => text().withLength(min: 1, max: 80)();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

class Expenses extends Table with SyncableTable {
  TextColumn get headId => text().references(ExpenseHeads, #id)();
  TextColumn get accountId => text().references(Accounts, #id)();
  IntColumn get amount => integer()();
  DateTimeColumn get spentOn => dateTime()();
  TextColumn get paidTo => text().withLength(max: 120).withDefault(const Constant(''))();
  TextColumn get reference => text().withLength(max: 80).withDefault(const Constant(''))();

  /// What it actually was, when the head chosen is "Other". Without this the
  /// biggest line in a month's expenses can end up labelled "Other".
  TextColumn get customHead => text().withLength(max: 120).withDefault(const Constant(''))();
  TextColumn get note => text().withDefault(const Constant(''))();
  BoolColumn get isCancelled => boolean().withDefault(const Constant(false))();
}

class SalaryPayments extends Table with SyncableTable {
  TextColumn get staffId => text().references(Staff, #id)();
  TextColumn get accountId => text().references(Accounts, #id)();
  TextColumn get periodKey => text().withLength(max: 20)();
  IntColumn get grossAmount => integer()();
  IntColumn get deductions => integer().withDefault(const Constant(0))();
  IntColumn get netAmount => integer()();
  DateTimeColumn get paidOn => dateTime()();
  TextColumn get note => text().withDefault(const Constant(''))();
  BoolColumn get isCancelled => boolean().withDefault(const Constant(false))();
}

/// End-of-day cash count against what the system believes.
class DailyClosings extends Table with SyncableTable {
  DateTimeColumn get closedFor => dateTime()();
  TextColumn get accountId => text().references(Accounts, #id)();
  IntColumn get expectedAmount => integer()();
  IntColumn get countedAmount => integer()();

  /// counted - expected. Stored so a later correction cannot rewrite history.
  IntColumn get difference => integer()();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get closedBy => text().withDefault(const Constant(''))();
}

// ===================== Stage 7 — attendance =====================

enum AttendanceState { present, absent, late, excused }

enum SessionState { planned, held, cancelled }

/// Whether a class was part of the normal routine or an extra sitting.
///
/// Drives per-class versus hourly pay: a teacher on both rates earns the
/// per-class rate for their routine classes and the hourly rate for extra
/// sittings, so the register has to record which kind each class was.
enum SessionKind { regular, extra }

/// One class that happened, or was meant to.
@TableIndex(name: 'idx_class_sessions_date', columns: {#heldOn})
@TableIndex(name: 'idx_class_sessions_batch', columns: {#batchId})
class ClassSessions extends Table with SyncableTable {
  TextColumn get batchId => text().references(Batches, #id)();
  TextColumn get subjectId => text().nullable().references(Subjects, #id)();
  TextColumn get staffId => text().nullable().references(Staff, #id)();
  TextColumn get roomId => text().nullable().references(Rooms, #id)();
  TextColumn get slotId => text().nullable().references(TimeSlots, #id)();
  DateTimeColumn get heldOn => dateTime()();
  TextColumn get state => textEnum<SessionState>()();
  TextColumn get kind => textEnum<SessionKind>()
      .withDefault(Constant(SessionKind.regular.name))();

  /// How long it ran. Only matters for hourly pay on extra sittings; routine
  /// classes are paid per class regardless of length.
  IntColumn get durationMinutes => integer().withDefault(const Constant(60))();
  TextColumn get note => text().withDefault(const Constant(''))();
}

@TableIndex(name: 'idx_attendance_session', columns: {#classSessionId})
@TableIndex(name: 'idx_attendance_student', columns: {#studentId})
class AttendanceRecords extends Table with SyncableTable {
  TextColumn get classSessionId => text().references(ClassSessions, #id)();
  TextColumn get studentId => text().references(Students, #id)();
  TextColumn get state => textEnum<AttendanceState>()();
  TextColumn get note => text().withDefault(const Constant(''))();
}

class StaffAttendance extends Table with SyncableTable {
  TextColumn get staffId => text().references(Staff, #id)();
  DateTimeColumn get onDate => dateTime()();
  TextColumn get state => textEnum<AttendanceState>()();
  TextColumn get note => text().withDefault(const Constant(''))();
}

// ===================== Stage 8 — inventory =====================

enum StockMove { receive, issue, damage, correction }

class InventoryItems extends Table with SyncableTable {
  TextColumn get name => text().withLength(min: 1, max: 120)();
  TextColumn get category => text().withLength(max: 60).withDefault(const Constant(''))();
  TextColumn get unit => text().withLength(max: 20).withDefault(const Constant('pcs'))();

  /// Kept as a running total so a list of two hundred items does not need two
  /// hundred aggregate queries to render.
  IntColumn get currentQuantity => integer().withDefault(const Constant(0))();
  IntColumn get minimumQuantity => integer().withDefault(const Constant(0))();
  IntColumn get purchasePrice => integer().withDefault(const Constant(0))();
  IntColumn get sellingPrice => integer().withDefault(const Constant(0))();
  TextColumn get supplier => text().withLength(max: 120).withDefault(const Constant(''))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

/// Every stock movement, with a reason. Append-only, like the ledger.
@TableIndex(name: 'idx_stock_item', columns: {#itemId})
class StockTransactions extends Table with SyncableTable {
  TextColumn get itemId => text().references(InventoryItems, #id)();
  TextColumn get move => textEnum<StockMove>()();

  /// Signed: positive adds to stock, negative removes.
  IntColumn get quantity => integer()();
  DateTimeColumn get occurredOn => dateTime()();
  TextColumn get reason => text().withDefault(const Constant(''))();
  TextColumn get reference => text().withLength(max: 80).withDefault(const Constant(''))();
}

// ===================== Stage 9/10 — routine =====================

/// A published or draft timetable.
///
/// Versioned rather than edited in place: a centre publishes a routine, prints
/// it for the notice board, and then wants to try changes without the printed
/// one silently drifting out of date.
class RoutineVersions extends Table with SyncableTable {
  TextColumn get sessionId => text().references(AcademicSessions, #id)();
  TextColumn get name => text().withLength(min: 1, max: 100)();
  BoolColumn get isPublished => boolean().withDefault(const Constant(false))();
  DateTimeColumn get publishedAt => dateTime().nullable()();
  TextColumn get note => text().withDefault(const Constant(''))();
}

/// One scheduled class: teacher + batch + subject + room + day + slot.
///
/// Every conflict the engine detects is a collision between two of these on one
/// of those axes.
@TableIndex(name: 'idx_routine_version', columns: {#routineVersionId})
class RoutineEntries extends Table with SyncableTable {
  TextColumn get routineVersionId => text().references(RoutineVersions, #id)();
  TextColumn get batchId => text().references(Batches, #id)();
  TextColumn get subjectId => text().references(Subjects, #id)();
  TextColumn get staffId => text().nullable().references(Staff, #id)();
  TextColumn get roomId => text().nullable().references(Rooms, #id)();
  TextColumn get slotId => text().references(TimeSlots, #id)();

  /// 1 = Saturday … 7 = Friday, matching how a Bangladeshi week is written.
  IntColumn get dayOfWeek => integer()();

  /// Placed by hand and protected from the solver.
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
}

/// When a teacher is available. Absence of a row means available.
class StaffAvailability extends Table with SyncableTable {
  TextColumn get staffId => text().references(Staff, #id)();
  IntColumn get dayOfWeek => integer()();
  TextColumn get slotId => text().references(TimeSlots, #id)();
  BoolColumn get isAvailable => boolean().withDefault(const Constant(true))();
}

/// How many periods a batch needs of a subject each week, and who teaches it.
class SubjectRequirements extends Table with SyncableTable {
  TextColumn get batchId => text().references(Batches, #id)();
  TextColumn get subjectId => text().references(Subjects, #id)();
  TextColumn get staffId => text().nullable().references(Staff, #id)();
  IntColumn get periodsPerWeek => integer().withDefault(const Constant(2))();

  /// Whether the same subject may appear twice in one day for this batch.
  BoolColumn get allowTwiceADay => boolean().withDefault(const Constant(false))();
}

// ===================== Stage 11 — questions =====================

enum QuestionType { mcq, cq, short, trueFalse, fillGap }

enum Difficulty { easy, medium, hard }

/// A question, stored as a first-class row from the start.
///
/// v1 exposes only "duplicate a paper", but questions live here rather than
/// inside a paper so the bank screen is later a new view over existing data
/// rather than a migration over a centre's live papers.
@TableIndex(name: 'idx_questions_subject', columns: {#subjectId})
class Questions extends Table with SyncableTable {
  TextColumn get subjectId => text().references(Subjects, #id)();
  TextColumn get chapterId => text().nullable().references(Chapters, #id)();
  TextColumn get type => textEnum<QuestionType>()();
  TextColumn get difficulty => textEnum<Difficulty>()();

  /// The question itself, as HTML — the Document Engine's native format.
  TextColumn get bodyHtml => text()();

  /// MCQ choices as a JSON array of strings.
  TextColumn get optionsJson => text().withDefault(const Constant('[]'))();
  IntColumn get correctOption => integer().nullable()();
  TextColumn get answerHtml => text().withDefault(const Constant(''))();
  IntColumn get marks => integer().withDefault(const Constant(1))();

  /// Where it came from — "Dhaka Board 2019".
  TextColumn get sourceTag => text().withLength(max: 120).withDefault(const Constant(''))();
  TextColumn get imagePath => text().nullable()();

  /// So the same question does not reappear in the same batch two terms running.
  DateTimeColumn get lastUsedAt => dateTime().nullable()();
  IntColumn get useCount => integer().withDefault(const Constant(0))();
}

/// Chapters within a subject, for tagging and blueprint selection.
class Chapters extends Table with SyncableTable {
  TextColumn get subjectId => text().references(Subjects, #id)();
  TextColumn get name => text().withLength(min: 1, max: 150)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

class QuestionPapers extends Table with SyncableTable {
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get subjectId => text().nullable().references(Subjects, #id)();
  TextColumn get classId => text().nullable().references(Classes, #id)();
  TextColumn get batchId => text().nullable().references(Batches, #id)();
  DateTimeColumn get examDate => dateTime().nullable()();
  IntColumn get durationMinutes => integer().withDefault(const Constant(120))();
  IntColumn get fullMarks => integer().withDefault(const Constant(100))();
  TextColumn get instructionsHtml => text().withDefault(const Constant(''))();

  /// How many shuffled variants to produce.
  IntColumn get setCount => integer().withDefault(const Constant(1))();
}

class PaperSections extends Table with SyncableTable {
  TextColumn get paperId => text().references(QuestionPapers, #id)();
  TextColumn get title => text().withLength(max: 150)();
  TextColumn get type => textEnum<QuestionType>()();
  TextColumn get instruction => text().withDefault(const Constant(''))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Answer any N of the questions listed. Zero means all of them.
  IntColumn get answerAny => integer().withDefault(const Constant(0))();
}

class PaperQuestions extends Table with SyncableTable {
  TextColumn get sectionId => text().references(PaperSections, #id)();
  TextColumn get questionId => text().references(Questions, #id)();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Overrides the question's own marks for this paper. Null uses the bank value.
  IntColumn get marksOverride => integer().nullable()();
}

// ===================== gap fills =====================

enum EnquiryStatus { open, followUp, admitted, lost }

/// A prospective student who has not enrolled yet.
class Enquiries extends Table with SyncableTable {
  TextColumn get name => text().withLength(min: 1, max: 150)();
  TextColumn get phone => text().withLength(max: 30).withDefault(const Constant(''))();
  TextColumn get phoneNorm => text().withLength(max: 20).withDefault(const Constant(''))();
  TextColumn get classId => text().nullable().references(Classes, #id)();
  TextColumn get source => text().withLength(max: 100).withDefault(const Constant(''))();
  TextColumn get status => textEnum<EnquiryStatus>()();
  DateTimeColumn get enquiredOn => dateTime()();
  DateTimeColumn get followUpOn => dateTime().nullable()();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get convertedStudentId => text().nullable().references(Students, #id)();
}

/// Links two students as siblings, so a family discount can be expressed and
/// the desk can see the whole family at once.
class StudentLinks extends Table with SyncableTable {
  TextColumn get studentId => text().references(Students, #id)();
  TextColumn get relatedStudentId => text().references(Students, #id)();
  TextColumn get relation => text().withLength(max: 40).withDefault(const Constant('sibling'))();
}

/// A closed accounting period.
///
/// Once a month is locked, nothing dated inside it can be written. This is what
/// stops a figure the owner has already reported from quietly changing.
class PeriodLocks extends Table with SyncableTable {
  TextColumn get periodKey => text().withLength(max: 20).unique()();
  DateTimeColumn get lockedAt => dateTime()();
  TextColumn get lockedBy => text().withDefault(const Constant(''))();
  TextColumn get note => text().withDefault(const Constant(''))();
}

// ===================== Stage 12 — print centre =====================

/// What kind of thing a print template is.
enum TemplateKind {
  /// A fixed design the centre already has, stored as a PDF or image and
  /// printed unchanged — the diary page, a blank attendance sheet, a notice
  /// letterhead.
  fixedFile,

  /// A layout the app fills from the database — ID cards, admit cards.
  mailMerge,
}

/// How often something needs reprinting.
enum PrintCadence {
  /// Only when asked.
  onDemand,
  weekly,

  /// Specific days of the month — the 1st and 16th, for a fortnightly diary.
  monthlyOnDays,
}

/// Something the centre prints regularly.
class PrintTemplates extends Table with SyncableTable {
  TextColumn get name => text().withLength(min: 1, max: 120)();
  TextColumn get kind => textEnum<TemplateKind>()();

  /// Where the uploaded file lives, for [TemplateKind.fixedFile].
  TextColumn get filePath => text().nullable()();

  /// Which built-in layout to use, for [TemplateKind.mailMerge].
  TextColumn get layout => text().withLength(max: 40).withDefault(const Constant(''))();

  TextColumn get paperSize => text().withLength(max: 10).withDefault(const Constant('A4'))();
  IntColumn get defaultCopies => integer().withDefault(const Constant(1))();

  TextColumn get cadence => textEnum<PrintCadence>()();

  /// Days of the month for [PrintCadence.monthlyOnDays], comma separated:
  /// `1,16` for a fortnightly reminder.
  TextColumn get cadenceDays => text().withLength(max: 40).withDefault(const Constant(''))();

  DateTimeColumn get lastPrintedAt => dateTime().nullable()();
  TextColumn get note => text().withDefault(const Constant(''))();
}

/// A record of something actually printed, so "when did we last run the diary
/// pages" has an answer.
class PrintJobs extends Table with SyncableTable {
  TextColumn get templateId => text().nullable().references(PrintTemplates, #id)();
  TextColumn get title => text().withLength(max: 150)();
  IntColumn get copies => integer().withDefault(const Constant(1))();
  DateTimeColumn get printedAt => dateTime()();
  TextColumn get printedBy => text().withDefault(const Constant(''))();
}

// ===================== round 1 feedback =====================

/// What kind of answer an admission-form field takes.
enum FormFieldType { text, longText, number, phone, date, choice }

/// A field on the centre's own admission form.
///
/// The form is built before anyone is admitted, and then it *is* the form.
/// Every centre asks for something the next one does not — madrasah background,
/// which bus route, whether a sibling already attends — and a fixed set of
/// columns would mean each of them keeping a paper form alongside the app.
class AdmissionFields extends Table with SyncableTable {
  TextColumn get label => text().withLength(min: 1, max: 120)();

  /// Stable key used to store answers, so renaming a label does not orphan the
  /// values already collected under it.
  TextColumn get fieldKey => text().withLength(min: 1, max: 60)();
  TextColumn get type => textEnum<FormFieldType>()();
  BoolColumn get isRequired => boolean().withDefault(const Constant(false))();

  /// Built-in fields map onto real columns on the student record — name, phone,
  /// fee — and cannot be deleted, only reordered or relabelled.
  BoolColumn get isBuiltIn => boolean().withDefault(const Constant(false))();

  /// Choices for [FormFieldType.choice], as a JSON array.
  TextColumn get optionsJson => text().withDefault(const Constant('[]'))();
  TextColumn get hint => text().withLength(max: 150).withDefault(const Constant(''))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

/// One student's answer to one custom field.
@TableIndex(name: 'idx_field_values_student', columns: {#studentId})
class StudentFieldValues extends Table with SyncableTable {
  TextColumn get studentId => text().references(Students, #id)();
  TextColumn get fieldId => text().references(AdmissionFields, #id)();
  TextColumn get value => text().withDefault(const Constant(''))();
}

/// Which classes a teacher takes.
///
/// Recorded explicitly rather than inferred from the routine, because the
/// centre knows who teaches what before any timetable exists — and the routine
/// builder needs it as an input, not an output.
class StaffClasses extends Table with SyncableTable {
  TextColumn get staffId => text().references(Staff, #id)();
  TextColumn get classId => text().references(Classes, #id)();
}
