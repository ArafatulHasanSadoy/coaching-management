import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';
import '../documents/document_engine.dart';
import '../finance/fee_service.dart';
import '../finance/ledger_service.dart';

/// A finished report, ready to show or print.
class Report {
  const Report({
    required this.title,
    required this.subtitle,
    required this.columns,
    required this.rows,
    this.totals = const [],
  });

  final String title;
  final String subtitle;
  final List<String> columns;
  final List<List<String>> rows;

  /// Rendered in bold under the table.
  final List<(String, String)> totals;
}

/// Answers the questions an owner actually asks.
///
/// Deliberately a small set of real questions rather than a report builder:
/// "what came in this month", "who owes me", "where did it go", "who is not
/// turning up". A generic query tool would be more powerful and would get used
/// less.
class ReportsService {
  const ReportsService({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  Future<Report> collections({
    required DateTime from,
    required DateTime to,
  }) async {
    final payments = await (db.select(db.payments).join([
      innerJoin(db.students, db.students.id.equalsExp(db.payments.studentId)),
    ])
          ..where(db.payments.receivedOn.isBiggerOrEqualValue(from) &
              db.payments.receivedOn.isSmallerThanValue(to) &
              db.payments.deletedAt.isNull())
          ..orderBy([OrderingTerm.desc(db.payments.receivedOn)]))
        .get();

    var collected = 0;
    var cancelled = 0;
    final rows = <List<String>>[];

    for (final row in payments) {
      final payment = row.readTable(db.payments);
      final student = row.readTable(db.students);
      if (payment.isCancelled) {
        cancelled += payment.amount;
      } else {
        collected += payment.amount;
      }

      rows.add([
        payment.receiptNo,
        _date(payment.receivedOn),
        student.name,
        payment.method.name,
        '${payment.amount}',
        payment.isCancelled ? 'CANCELLED' : '',
      ]);
    }

    return Report(
      title: 'Collections',
      subtitle: '${_date(from)} to ${_date(to.subtract(const Duration(days: 1)))}',
      columns: const ['Receipt', 'Date', 'Student', 'Method', 'Amount', ''],
      rows: rows,
      totals: [
        ('Receipts', '${payments.length}'),
        ('Collected', '৳$collected'),
        if (cancelled > 0) ('Cancelled', '৳$cancelled'),
      ],
    );
  }

  Future<Report> expenses({
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await (db.select(db.expenses).join([
      innerJoin(db.expenseHeads,
          db.expenseHeads.id.equalsExp(db.expenses.headId)),
    ])
          ..where(db.expenses.spentOn.isBiggerOrEqualValue(from) &
              db.expenses.spentOn.isSmallerThanValue(to) &
              db.expenses.deletedAt.isNull())
          ..orderBy([OrderingTerm.desc(db.expenses.spentOn)]))
        .get();

    final byHead = <String, int>{};
    var total = 0;
    final table = <List<String>>[];

    for (final row in rows) {
      final expense = row.readTable(db.expenses);
      final head = row.readTable(db.expenseHeads);
      // "Other" as the biggest line in a month tells the owner nothing, so the
      // typed description stands in for the head wherever one was given.
      final label = expense.customHead.isEmpty
          ? head.name
          : '${head.name} — ${expense.customHead}';

      if (!expense.isCancelled) {
        total += expense.amount;
        byHead.update(label, (n) => n + expense.amount,
            ifAbsent: () => expense.amount);
      }
      table.add([
        _date(expense.spentOn),
        label,
        expense.paidTo,
        '${expense.amount}',
        expense.isCancelled ? 'CANCELLED' : '',
      ]);
    }

    final ranked = byHead.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Report(
      title: 'Expenses',
      subtitle: '${_date(from)} to ${_date(to.subtract(const Duration(days: 1)))}',
      columns: const ['Date', 'Head', 'Paid to', 'Amount', ''],
      rows: table,
      totals: [
        ('Total', '৳$total'),
        for (final entry in ranked.take(3)) (entry.key, '৳${entry.value}'),
      ],
    );
  }

  Future<Report> outstanding() async {
    final defaulters =
        await FeeService(db: db, deviceId: deviceId).defaulters();

    return Report(
      title: 'Outstanding fees',
      subtitle: 'As at ${_date(DateTime.now())}',
      columns: const ['Student', 'ID', 'Guardian phone', 'Months', 'Due'],
      rows: [
        for (final due in defaulters)
          [
            due.student.name,
            due.student.code,
            due.student.guardianPhone,
            '${due.monthsBehind}',
            '${due.totalDue}',
          ],
      ],
      totals: [
        ('Students', '${defaulters.length}'),
        ('Total due', '৳${defaulters.fold<int>(0, (s, d) => s + d.totalDue)}'),
      ],
    );
  }

  Future<Report> profitAndLoss({
    required DateTime from,
    required DateTime to,
  }) async {
    final totals = await LedgerService(db: db, deviceId: deviceId)
        .totalsBetween(from, to);

    return Report(
      title: 'Income and expenses',
      subtitle: '${_date(from)} to ${_date(to.subtract(const Duration(days: 1)))}',
      columns: const ['', 'Amount'],
      rows: [
        ['Money in', '৳${totals.income}'],
        ['Money out', '৳${totals.expense}'],
      ],
      totals: [('Net', '৳${totals.income - totals.expense}')],
    );
  }

  /// Students below an attendance threshold — the ones to ring.
  Future<Report> lowAttendance({
    required DateTime from,
    required DateTime to,
    double below = 70,
  }) async {
    final rows = await (db.select(db.attendanceRecords).join([
      innerJoin(db.classSessions,
          db.classSessions.id.equalsExp(db.attendanceRecords.classSessionId)),
      innerJoin(db.students,
          db.students.id.equalsExp(db.attendanceRecords.studentId)),
    ])
          ..where(db.classSessions.heldOn.isBiggerOrEqualValue(from) &
              db.classSessions.heldOn.isSmallerThanValue(to) &
              db.attendanceRecords.deletedAt.isNull() &
              db.students.deletedAt.isNull()))
        .get();

    final tally = <String, (Student, int, int)>{};
    for (final row in rows) {
      final student = row.readTable(db.students);
      final record = row.readTable(db.attendanceRecords);
      final present = record.state == AttendanceState.present ||
          record.state == AttendanceState.late;

      final current = tally[student.id] ?? (student, 0, 0);
      tally[student.id] =
          (student, current.$2 + 1, current.$3 + (present ? 1 : 0));
    }

    final flagged = <List<String>>[];
    for (final (student, held, present) in tally.values) {
      if (held == 0) continue;
      final percent = present / held * 100;
      if (percent >= below) continue;
      flagged.add([
        student.name,
        student.code,
        student.guardianPhone,
        '$present/$held',
        '${percent.toStringAsFixed(0)}%',
      ]);
    }
    flagged.sort((a, b) => a.last.compareTo(b.last));

    return Report(
      title: 'Low attendance',
      subtitle: 'Below ${below.toStringAsFixed(0)}%, '
          '${_date(from)} to ${_date(to.subtract(const Duration(days: 1)))}',
      columns: const ['Student', 'ID', 'Guardian phone', 'Attended', 'Rate'],
      rows: flagged,
      totals: [('Students', '${flagged.length}')],
    );
  }

  /// Renders a report for printing, through the shared Document Engine.
  String toHtml(Report report, DocumentEngine engine) {
    final buffer = StringBuffer()
      ..writeln('<div class="doc-title">${DocumentEngine.escape(report.title)}</div>')
      ..writeln('<div style="text-align:center;font-size:9.5pt;color:#444;'
          'margin-bottom:4mm">${DocumentEngine.escape(report.subtitle)}</div>')
      ..writeln('<table style="font-size:10pt">')
      ..writeln('<tr>${report.columns.map((c) =>
          '<th align="left" style="border-bottom:1px solid #000">'
          '${DocumentEngine.escape(c)}</th>').join()}</tr>');

    for (final row in report.rows) {
      buffer.writeln('<tr>${row.map((cell) =>
          '<td style="border-bottom:1px solid #eee">'
          '${DocumentEngine.escape(cell)}</td>').join()}</tr>');
    }
    buffer.writeln('</table>');

    if (report.totals.isNotEmpty) {
      buffer.writeln('<table class="totals" style="margin-top:4mm">');
      for (final (label, value) in report.totals) {
        buffer.writeln('<tr><td><b>${DocumentEngine.escape(label)}</b></td>'
            '<td align="right"><b>${DocumentEngine.escape(value)}</b></td></tr>');
      }
      buffer.writeln('</table>');
    }

    return engine.page(title: report.title, body: buffer.toString());
  }

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}
