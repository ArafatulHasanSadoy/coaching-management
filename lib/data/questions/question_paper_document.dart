import '../db/database.dart';
import '../db/tables.dart';
import '../documents/document_engine.dart';
import 'paper_model.dart';

/// Renders a question paper.
///
/// The layout rules here are the ones Stage 0 proved on physical paper:
/// two-column MCQ via `column-count`, `break-inside: avoid` so a question never
/// splits across a page or column, and native MathML for equations — no KaTeX,
/// which means JavaScript stays off in the print WebView.
class QuestionPaperDocument {
  const QuestionPaperDocument({required this.engine});

  final DocumentEngine engine;

  static const _css = '''
  .exam-title { text-align: center; font-size: 13pt; font-weight: 700;
                margin: 4mm 0 2mm; }
  .exam-bar { display: flex; justify-content: space-between;
              font-size: 10.5pt; font-weight: 600; margin-bottom: 3mm;
              border-bottom: 1px solid #999; padding-bottom: 2mm; }
  .set-badge { border: 1.5px solid #000; border-radius: 3px;
               padding: 0 2mm; font-weight: 700; }
  h2.section { font-size: 11.5pt; margin: 6mm 0 2mm; padding: 1.5mm 3mm;
               background: #f0f0f0; border-left: 3px solid #000; }
  .section-note { font-size: 9.5pt; color: #444; margin: 0 0 2mm 3mm; }
  .mcq { column-count: 2; column-gap: 9mm; }
  .q { break-inside: avoid; page-break-inside: avoid; margin-bottom: 3.5mm; }
  .q .marks { float: right; font-weight: 700; }
  .opts { display: grid; grid-template-columns: 1fr 1fr; margin-top: .5mm;
          font-size: 10.5pt; }
  .cq ol { margin: 1mm 0 0 8mm; padding: 0; list-style: bn-alpha; }
  .answer-space { border: 1px dashed #999; height: 20mm; margin-top: 2mm; }
  .figure img { max-width: 70mm; display: block; margin: 2mm 0; }
  .keys { column-count: 4; column-gap: 6mm; font-size: 10.5pt; }
  .page-break { break-before: page; page-break-before: always; }

  /* HTML has no Bengali list type, so sub-questions need a counter style. */
  @counter-style bn-alpha {
    system: fixed;
    symbols: "ক" "খ" "গ" "ঘ" "ঙ" "চ";
    suffix: ") ";
  }
''';

  String build({
    required QuestionPaper paper,
    required List<PaperSet> sets,
    String subjectName = '',
    String className = '',
    bool includeAnswerKey = false,
  }) {
    final buffer = StringBuffer();

    for (var i = 0; i < sets.length; i++) {
      if (i > 0) buffer.writeln('<div class="page-break"></div>');
      buffer.writeln(_paperBody(
        paper: paper,
        set: sets[i],
        subjectName: subjectName,
        className: className,
        showSetBadge: sets.length > 1,
      ));
    }

    if (includeAnswerKey) {
      for (final set in sets) {
        if (set.answerKey.isEmpty) continue;
        buffer
          ..writeln('<div class="page-break"></div>')
          ..writeln(_answerKey(paper, set, sets.length > 1));
      }
    }

    return engine.page(
      title: paper.title,
      body: buffer.toString(),
      extraCss: _css,
      showLetterhead: false,
    );
  }

  String _paperBody({
    required QuestionPaper paper,
    required PaperSet set,
    required String subjectName,
    required String className,
    required bool showSetBadge,
  }) {
    final buffer = StringBuffer()
      ..writeln(engine.letterheadHtml())
      ..writeln('<div class="exam-title">${DocumentEngine.escape(paper.title)}'
          '${showSetBadge ? ' <span class="set-badge">SET ${set.label}</span>' : ''}'
          '</div>')
      ..writeln('<div class="exam-bar">')
      ..writeln('<span>${DocumentEngine.escape(subjectName)}</span>')
      ..writeln('<span>${DocumentEngine.escape(className)}</span>')
      ..writeln('<span>Time: ${_duration(paper.durationMinutes)}</span>')
      ..writeln('<span>Full marks: ${paper.fullMarks}</span>')
      ..writeln('</div>');

    if (paper.instructionsHtml.isNotEmpty) {
      buffer.writeln('<div class="section-note">${paper.instructionsHtml}</div>');
    }

    var number = 1;
    for (final section in set.sections) {
      buffer.writeln(
        '<h2 class="section">${DocumentEngine.escape(section.section.title)}'
        ' &nbsp;(${section.totalMarks})</h2>',
      );
      if (section.section.instruction.isNotEmpty) {
        buffer.writeln('<div class="section-note">'
            '${DocumentEngine.escape(section.section.instruction)}</div>');
      }
      if (section.section.answerAny > 0) {
        buffer.writeln('<div class="section-note">Answer any '
            '${section.section.answerAny} of ${section.items.length}.</div>');
      }

      final isMcq = section.section.type == QuestionType.mcq;
      buffer.writeln(isMcq ? '<div class="mcq">' : '<div class="cq">');

      for (final item in section.items) {
        buffer
          ..writeln('<div class="q">')
          ..writeln('<span class="marks">${item.marks}</span>')
          ..writeln('$number। ${item.question.bodyHtml}');

        if (item.question.imagePath != null) {
          buffer.writeln('<div class="figure">'
              '<img src="file://${item.question.imagePath}" alt=""></div>');
        }

        if (isMcq && item.options.isNotEmpty) {
          buffer.writeln('<div class="opts">');
          const letters = ['ক', 'খ', 'গ', 'ঘ', 'ঙ'];
          for (var i = 0; i < item.options.length; i++) {
            buffer.writeln('<span>(${letters[i % letters.length]}) '
                '${DocumentEngine.escape(item.options[i])}</span>');
          }
          buffer.writeln('</div>');
        } else if (!isMcq) {
          buffer.writeln('<div class="answer-space"></div>');
        }

        buffer.writeln('</div>');
        number++;
      }
      buffer.writeln('</div>');
    }

    return buffer.toString();
  }

  String _answerKey(QuestionPaper paper, PaperSet set, bool showSet) {
    final entries = set.answerKey.entries.toList()
      ..sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key)));

    return '''
${engine.letterheadHtml()}
<div class="exam-title">ANSWER KEY — ${DocumentEngine.escape(paper.title)}
${showSet ? '<span class="set-badge">SET ${set.label}</span>' : ''}</div>
<div class="keys">
${entries.map((e) => '<div>${e.key}. <b>${e.value}</b></div>').join('\n')}
</div>''';
  }

  static String _duration(int minutes) {
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    if (hours == 0) return '$rest minutes';
    if (rest == 0) return '$hours hour${hours == 1 ? '' : 's'}';
    return '$hours h $rest m';
  }
}
