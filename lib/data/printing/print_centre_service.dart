import 'dart:io';

import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';

/// Something that needs printing, and why.
class DuePrint {
  const DuePrint({required this.template, required this.reason});

  final PrintTemplate template;

  /// Phrased for the person who has to walk to the printer.
  final String reason;
}

/// The forms a centre prints on a rhythm.
///
/// Every centre has a handful of fixed pages — the fortnightly diary sheet, a
/// blank attendance register, a notice letterhead — that get reprinted forever
/// and are currently remembered by somebody. Storing them once and reminding on
/// the right day turns that into a tap.
class PrintCentreService {
  const PrintCentreService({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  Stream<List<PrintTemplate>> watchTemplates() => (db.select(db.printTemplates)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .watch();

  /// Copies an uploaded file into the app's own storage.
  ///
  /// A template that points at wherever the picker found it breaks the moment
  /// the owner tidies their downloads, and the backup would not contain it.
  Future<PrintTemplate> addFixedFile({
    required String name,
    required File source,
    required Directory mediaDir,
    String paperSize = 'A4',
    int copies = 1,
    PrintCadence cadence = PrintCadence.onDemand,
    List<int> days = const [],
    String note = '',
  }) async {
    final dir = Directory('${mediaDir.path}/print_templates');
    await dir.create(recursive: true);

    final extension = source.path.contains('.')
        ? source.path.substring(source.path.lastIndexOf('.'))
        : '.pdf';
    final target =
        File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}$extension');
    await source.copy(target.path);

    final row = await db.into(db.printTemplates).insertReturning(
          PrintTemplatesCompanion.insert(
            name: name.trim(),
            kind: TemplateKind.fixedFile,
            cadence: cadence,
            deviceId: deviceId,
            filePath: Value(target.path),
            paperSize: Value(paperSize),
            defaultCopies: Value(copies),
            cadenceDays: Value(days.join(',')),
            note: Value(note),
          ),
        );

    await db.recordChange(
      entity: 'print_templates',
      entityId: row.id,
      op: ChangeOp.insert,
      deviceId: deviceId,
      action: 'template_added',
      after: {'name': name, 'cadence': cadence.name},
    );
    return row;
  }

  Future<void> updateCadence(
    PrintTemplate template, {
    required PrintCadence cadence,
    List<int> days = const [],
    int? copies,
  }) async {
    await (db.update(db.printTemplates)
          ..where((t) => t.id.equals(template.id)))
        .write(
      PrintTemplatesCompanion(
        cadence: Value(cadence),
        cadenceDays: Value(days.join(',')),
        defaultCopies: Value(copies ?? template.defaultCopies),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> archive(PrintTemplate template) async {
    await (db.update(db.printTemplates)
          ..where((t) => t.id.equals(template.id)))
        .write(
      PrintTemplatesCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
    await db.recordChange(
      entity: 'print_templates',
      entityId: template.id,
      op: ChangeOp.softDelete,
      deviceId: deviceId,
      action: 'template_archived',
      before: {'name': template.name},
    );
  }

  /// Records that something was printed, and stops it nagging.
  Future<void> recordPrinted(
    PrintTemplate template, {
    int? copies,
    String by = '',
    DateTime? at,
  }) async {
    final when = at ?? DateTime.now();
    await db.transaction(() async {
      await db.into(db.printJobs).insert(
            PrintJobsCompanion.insert(
              title: template.name,
              printedAt: when,
              deviceId: deviceId,
              templateId: Value(template.id),
              copies: Value(copies ?? template.defaultCopies),
              printedBy: Value(by),
            ),
          );
      await (db.update(db.printTemplates)
            ..where((t) => t.id.equals(template.id)))
          .write(
        PrintTemplatesCompanion(
          lastPrintedAt: Value(when),
          updatedAt: Value(when),
        ),
      );
    });
  }

  Future<List<PrintJob>> history({int limit = 50}) => (db.select(db.printJobs)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.desc(t.printedAt)])
        ..limit(limit))
      .get();

  /// What is due today.
  ///
  /// "Due" means the scheduled day has arrived and it has not been printed
  /// since that day began — so a reminder disappears once acted on, and a
  /// template printed early does not nag again on the day.
  Future<List<DuePrint>> dueNow({DateTime? on}) async {
    final today = on ?? DateTime.now();
    final templates = await (db.select(db.printTemplates)
          ..where((t) => t.deletedAt.isNull()))
        .get();

    final due = <DuePrint>[];
    for (final template in templates) {
      final since = _mostRecentDueDate(template, today);
      if (since == null) continue;

      final printed = template.lastPrintedAt;
      if (printed != null && !printed.isBefore(since)) continue;

      final days = today.difference(since).inDays;
      due.add(
        DuePrint(
          template: template,
          reason: days == 0
              ? 'Due today'
              : days == 1
                  ? 'Was due yesterday'
                  : 'Was due $days days ago',
        ),
      );
    }
    return due;
  }

  /// The most recent date on or before [today] that this template was supposed
  /// to be printed, or null if it has no schedule.
  static DateTime? _mostRecentDueDate(PrintTemplate template, DateTime today) {
    final day = DateTime(today.year, today.month, today.day);

    switch (template.cadence) {
      case PrintCadence.onDemand:
        return null;

      case PrintCadence.weekly:
        // Weeks start Saturday, as a Bangladeshi week does.
        final daysSinceSaturday = (day.weekday + 1) % 7;
        return day.subtract(Duration(days: daysSinceSaturday));

      case PrintCadence.monthlyOnDays:
        final days = template.cadenceDays
            .split(',')
            .map((d) => int.tryParse(d.trim()))
            .whereType<int>()
            .where((d) => d >= 1 && d <= 31)
            .toList()
          ..sort();
        if (days.isEmpty) return null;

        // The latest scheduled day already reached this month...
        final passed = days.where((d) => d <= day.day).toList();
        if (passed.isNotEmpty) {
          return DateTime(day.year, day.month, passed.last);
        }

        // ...otherwise the last one of the previous month.
        final previous = DateTime(day.year, day.month - 1);
        final lastDayOfPrevious =
            DateTime(previous.year, previous.month + 1, 0).day;
        final candidate = days.last > lastDayOfPrevious
            ? lastDayOfPrevious
            : days.last;
        return DateTime(previous.year, previous.month, candidate);
    }
  }
}
