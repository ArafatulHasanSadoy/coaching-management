import '../../data/documents/document_engine.dart';
import '../../data/routine/routine_model.dart';

/// A printable timetable.
///
/// One grid per class rather than one giant matrix, with every batch of that
/// class merged into the same sheet — that is what goes on the notice board,
/// and a wall chart nobody can read from two metres away is not worth printing.
class RoutineDocument {
  const RoutineDocument({required this.engine});

  final DocumentEngine engine;

  static const _css = '''
  table.grid { border-collapse: collapse; width: 100%; margin-bottom: 6mm; }
  table.grid th, table.grid td { border: 1px solid #666; padding: 2mm 1.5mm;
                                 font-size: 9.5pt; vertical-align: top;
                                 text-align: center; }
  table.grid th { background: #eee; font-size: 9pt; }
  table.grid td .subject { font-weight: 700; }
  table.grid td .batch { font-size: 8pt; font-weight: 600; }
  table.grid td .who { font-size: 8pt; color: #333; }
  table.grid td .split { border-top: 1px dotted #999; margin-top: 1.2mm;
                         padding-top: 1.2mm; }
  .grid-title { font-size: 12pt; font-weight: 700; margin: 4mm 0 1mm; }
  .grid-sub { font-size: 9pt; color: #444; margin-bottom: 2mm; }
  .page-break { break-before: page; page-break-before: always; }
''';

  String build({
    required RoutineProblem problem,
    required List<Placement> placements,
    required String versionName,
    String? classId,
    String? batchId,
  }) {
    // Preserve the order the batches arrive in — the repository already sorts
    // them by class.
    //
    // A batchId narrows to one batch's own sheet, which is what gets handed to
    // a teacher; a classId gives the merged class sheet for the notice board.
    final classes = <String, List<BatchRef>>{};
    for (final batch in problem.batches) {
      if (batchId != null && batch.id != batchId) continue;
      if (classId != null && batch.classId != classId) continue;
      classes.putIfAbsent(batch.classId, () => []).add(batch);
    }

    final buffer = StringBuffer();
    var first = true;
    for (final entry in classes.entries) {
      if (!first) buffer.writeln('<div class="page-break"></div>');
      first = false;
      buffer.writeln(
        _gridFor(problem, placements, entry.value, versionName),
      );
    }
    return engine.page(
      title: 'Routine — $versionName',
      body: buffer.toString(),
      extraCss: _css,
    );
  }

  String _gridFor(
    RoutineProblem problem,
    List<Placement> placements,
    List<BatchRef> batches,
    String versionName,
  ) {
    final ids = {for (final b in batches) b.id};
    final mine = placements.where((p) => ids.contains(p.batchId)).toList();
    final showBatch = batches.length > 1;

    final buffer = StringBuffer()
      ..writeln('<div class="grid-title">'
          '${DocumentEngine.escape(showBatch ? batches.first.className : batches.first.name)}'
          ' &nbsp;<span style="font-weight:400;font-size:10pt">'
          '${DocumentEngine.escape(versionName)}</span></div>')
      ..writeln('<div class="grid-sub">'
          '${DocumentEngine.escape(showBatch ? batches.map((b) => b.name).join(' · ') : batches.first.className)}'
          '</div>')
      ..writeln('<table class="grid"><tr><th></th>');

    for (final day in problem.days) {
      buffer.writeln('<th>${bengaliWeek[day]}</th>');
    }
    buffer.writeln('</tr>');

    for (final slot in problem.slots) {
      buffer.writeln('<tr><th>${DocumentEngine.escape(slot.label)}</th>');
      for (final day in problem.days) {
        final cell =
            mine.where((p) => p.day == day && p.slotId == slot.id).toList();
        if (cell.isEmpty) {
          buffer.writeln('<td></td>');
          continue;
        }
        buffer.write('<td>');
        for (var i = 0; i < cell.length; i++) {
          buffer
            ..write(i == 0 ? '<div>' : '<div class="split">')
            ..write('<div class="subject">'
                '${DocumentEngine.escape(problem.nameOfSubject(cell[i].subjectId))}'
                '</div>');
          if (showBatch) {
            buffer.write('<div class="batch">'
                '${DocumentEngine.escape(problem.nameOfBatch(cell[i].batchId))}'
                '</div>');
          }
          buffer
            ..write('<div class="who">${DocumentEngine.escape([
                  if (cell[i].staffId != null)
                    problem.nameOfStaff(cell[i].staffId!),
                  if (cell[i].roomId != null)
                    problem.nameOfRoom(cell[i].roomId!),
                ].join(' · '))}</div>')
            ..write('</div>');
        }
        buffer.writeln('</td>');
      }
      buffer.writeln('</tr>');
    }
    buffer.writeln('</table>');
    return buffer.toString();
  }
}
