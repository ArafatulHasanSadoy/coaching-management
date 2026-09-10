import '../db/database.dart';
import '../documents/document_engine.dart';

/// Student ID cards, laid out several to a page.
///
/// A mail-merge template rather than a fixed file: the design is the same every
/// time, the names are not. Cards are printed in a grid so a batch of forty
/// does not cost forty sheets.
class IdCardDocument {
  const IdCardDocument({required this.engine});

  final DocumentEngine engine;

  static const _css = '''
  .sheet { display: grid; grid-template-columns: 1fr 1fr;
           gap: 6mm; }
  .card { border: 1px solid #000; border-radius: 2mm; padding: 4mm;
          height: 52mm; break-inside: avoid; page-break-inside: avoid;
          display: flex; flex-direction: column; }
  .card .top { display: flex; align-items: center; gap: 3mm;
               border-bottom: 1px solid #999; padding-bottom: 2mm; }
  .card .centre { font-size: 10pt; font-weight: 700; line-height: 1.2; }
  .card .who { margin-top: 3mm; }
  .card .name { font-size: 12pt; font-weight: 700; }
  .card .kv { font-size: 8.5pt; color: #333; }
  .card .foot { margin-top: auto; font-size: 7.5pt; color: #555;
                border-top: 1px solid #ddd; padding-top: 1.5mm; }
  .photo { width: 16mm; height: 16mm; border: 1px solid #999;
           object-fit: cover; }
''';

  String build({
    required List<Student> students,
    required String centreName,
    String centrePhone = '',
    Map<String, String> batchNames = const {},
    String validUntil = '',
  }) {
    final cards = StringBuffer('<div class="sheet">');

    for (final student in students) {
      final photo = student.photoPath;
      cards.writeln('''
<div class="card">
  <div class="top">
    ${photo == null ? '<div class="photo"></div>' : '<img class="photo" src="file://${DocumentEngine.escape(photo)}" alt="">'}
    <div class="centre">${DocumentEngine.escape(centreName)}</div>
  </div>
  <div class="who">
    <div class="name">${DocumentEngine.escape(student.name)}</div>
    <div class="kv">ID: ${DocumentEngine.escape(student.code)}</div>
    ${batchNames[student.id] == null ? '' : '<div class="kv">${DocumentEngine.escape(batchNames[student.id]!)}</div>'}
    ${student.guardianPhone.isEmpty ? '' : '<div class="kv">Guardian: ${DocumentEngine.escape(student.guardianPhone)}</div>'}
    ${student.bloodGroup.isEmpty ? '' : '<div class="kv">Blood: ${DocumentEngine.escape(student.bloodGroup)}</div>'}
  </div>
  <div class="foot">
    ${DocumentEngine.escape(centrePhone)}
    ${validUntil.isEmpty ? '' : ' &nbsp;•&nbsp; Valid to ${DocumentEngine.escape(validUntil)}'}
  </div>
</div>''');
    }
    cards.writeln('</div>');

    return engine.page(
      title: 'ID cards',
      body: cards.toString(),
      extraCss: _css,
      showLetterhead: false,
    );
  }
}
