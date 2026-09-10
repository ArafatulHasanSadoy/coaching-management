import 'dart:convert';

import 'package:coaching_ops/data/db/database.dart';
import 'package:coaching_ops/data/db/tables.dart';
import 'package:coaching_ops/data/documents/document_engine.dart';
import 'package:coaching_ops/data/questions/paper_model.dart';
import 'package:coaching_ops/data/questions/question_paper_document.dart';
import 'package:flutter_test/flutter_test.dart';

Question q({
  required String id,
  QuestionType type = QuestionType.mcq,
  Difficulty difficulty = Difficulty.medium,
  int marks = 1,
  String body = 'Question body',
  List<String> options = const ['ক', 'খ', 'গ', 'ঘ'],
  int? correct = 0,
  String? chapterId,
  DateTime? lastUsed,
  int useCount = 0,
}) =>
    Question(
      id: id,
      subjectId: 'sub1',
      chapterId: chapterId,
      type: type,
      difficulty: difficulty,
      bodyHtml: body,
      optionsJson: jsonEncode(options),
      correctOption: correct,
      answerHtml: '',
      marks: marks,
      sourceTag: '',
      imagePath: null,
      lastUsedAt: lastUsed,
      useCount: useCount,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      deletedAt: null,
      deviceId: 'device-a',
    );

PaperSection section({
  required String id,
  String title = 'Section',
  QuestionType type = QuestionType.mcq,
  int answerAny = 0,
}) =>
    PaperSection(
      id: id,
      paperId: 'paper1',
      title: title,
      type: type,
      instruction: '',
      sortOrder: 0,
      answerAny: answerAny,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      deletedAt: null,
      deviceId: 'device-a',
    );

ComposedSection composed(PaperSection s, List<Question> questions) =>
    ComposedSection(
      section: s,
      items: [
        for (final question in questions)
          PaperItem(
            question: question,
            marks: question.marks,
            options: PaperComposer.optionsOf(question),
            correctOption: question.correctOption,
          ),
      ],
    );

void main() {
  group('marks validation', () {
    test('catches a paper that does not add up', () {
      final sections = [
        composed(section(id: 's1'), [
          for (var i = 0; i < 10; i++) q(id: 'q$i', marks: 1),
        ]),
        composed(section(id: 's2', type: QuestionType.cq), [
          for (var i = 0; i < 5; i++)
            q(id: 'cq$i', type: QuestionType.cq, marks: 7),
        ]),
      ];

      final check = PaperComposer.check(sections: sections, fullMarks: 50);
      expect(check.actual, 45);
      expect(check.matches, isFalse);
      expect(check.warning, contains('45'));
      expect(check.warning, contains('5 short'));
    });

    test('is silent when the paper is right', () {
      final sections = [
        composed(section(id: 's1'), [
          for (var i = 0; i < 10; i++) q(id: 'q$i', marks: 2),
        ]),
      ];
      final check = PaperComposer.check(sections: sections, fullMarks: 20);
      expect(check.matches, isTrue);
      expect(check.warning, isNull);
    });

    test('"answer any five of eight" counts five, not eight', () {
      final s = section(id: 's1', type: QuestionType.cq, answerAny: 5);
      final sections = [
        composed(s, [
          for (var i = 0; i < 8; i++)
            q(id: 'cq$i', type: QuestionType.cq, marks: 10),
        ]),
      ];

      expect(sections.single.totalMarks, 50);
      expect(
        PaperComposer.check(sections: sections, fullMarks: 50).matches,
        isTrue,
      );
    });
  });

  group('blueprint selection', () {
    test('picks the requested count, type and difficulty', () {
      final pool = [
        for (var i = 0; i < 10; i++)
          q(id: 'easy$i', difficulty: Difficulty.easy),
        for (var i = 0; i < 10; i++)
          q(id: 'hard$i', difficulty: Difficulty.hard),
        for (var i = 0; i < 5; i++)
          q(id: 'cq$i', type: QuestionType.cq),
      ];

      final chosen = Blueprint.select(
        pool: pool,
        rule: const BlueprintRule(
          type: QuestionType.mcq,
          count: 6,
          difficulty: Difficulty.easy,
        ),
      );

      expect(chosen, hasLength(6));
      expect(chosen.every((c) => c.type == QuestionType.mcq), isTrue);
      expect(chosen.every((c) => c.difficulty == Difficulty.easy), isTrue);
    });

    test('restricts to the chapters asked for', () {
      final pool = [
        q(id: 'a', chapterId: 'ch1'),
        q(id: 'b', chapterId: 'ch2'),
        q(id: 'c', chapterId: 'ch3'),
      ];
      final chosen = Blueprint.select(
        pool: pool,
        rule: const BlueprintRule(
          type: QuestionType.mcq,
          count: 5,
          chapterIds: ['ch1', 'ch2'],
        ),
      );
      expect(chosen.map((c) => c.id).toSet(), {'a', 'b'});
    });

    test('prefers questions the class has not seen recently', () {
      final now = DateTime(2026, 9, 10);
      final pool = [
        q(id: 'fresh', lastUsed: null),
        q(id: 'old', lastUsed: DateTime(2025, 1, 1)),
        q(id: 'lastWeek', lastUsed: DateTime(2026, 9, 3)),
      ];

      final chosen = Blueprint.select(
        pool: pool,
        rule: const BlueprintRule(type: QuestionType.mcq, count: 2),
        now: now,
      );

      expect(
        chosen.map((c) => c.id),
        isNot(contains('lastWeek')),
        reason: 'a question used last week should be the last one reused',
      );
    });
  });

  group('shuffled sets', () {
    final questions = [
      for (var i = 0; i < 6; i++)
        q(id: 'q$i', options: ['A$i', 'B$i', 'C$i', 'D$i'], correct: i % 4),
    ];
    final sections = [composed(section(id: 's1'), questions)];

    test('set A is the paper exactly as composed', () {
      final sets = PaperComposer.compose(sections: sections, setCount: 3);
      expect(sets.first.label, 'A');
      expect(
        sets.first.sections.single.items.map((i) => i.question.id).toList(),
        questions.map((x) => x.id).toList(),
      );
    });

    test('later sets reorder the questions', () {
      final sets = PaperComposer.compose(sections: sections, setCount: 3);
      final a = sets[0].sections.single.items.map((i) => i.question.id).toList();
      final b = sets[1].sections.single.items.map((i) => i.question.id).toList();

      expect(b.toSet(), a.toSet(), reason: 'same questions');
      expect(b, isNot(a), reason: 'different order');
    });

    test('the answer key follows the shuffle', () {
      final sets = PaperComposer.compose(sections: sections, setCount: 4);

      for (final set in sets) {
        var number = 1;
        for (final item in set.sections.single.items) {
          final keyLetter = set.answerKey['$number']!;
          final keyIndex = keyLetter.codeUnitAt(0) - 65;

          // The letter in the key must point at the option that is actually
          // correct in *this* set. A shuffled paper with the original key is
          // worse than no shuffling at all.
          final original = item.question;
          final correctText =
              PaperComposer.optionsOf(original)[original.correctOption!];
          expect(
            item.options[keyIndex],
            correctText,
            reason: 'set ${set.label}, question $number',
          );
          number++;
        }
      }
    });

    test('every set carries the same total marks', () {
      final sets = PaperComposer.compose(sections: sections, setCount: 3);
      expect(sets.map((s) => s.totalMarks).toSet(), hasLength(1));
    });
  });

  group('the printed paper', () {
    final paper = QuestionPaper(
      id: 'paper1',
      title: 'প্রথম সাময়িক পরীক্ষা — ২০২৬',
      subjectId: 'sub1',
      classId: 'class1',
      batchId: null,
      examDate: DateTime(2026, 3, 1),
      durationMinutes: 120,
      fullMarks: 50,
      instructionsHtml: 'সকল প্রশ্নের উত্তর দাও।',
      setCount: 2,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      deletedAt: null,
      deviceId: 'device-a',
    );

    test('renders Bangla, two-column MCQ and per-question marks', () {
      final sections = [
        composed(section(id: 's1', title: 'ক-বিভাগ: বহুনির্বাচনি'), [
          q(id: 'q1', body: 'বেগের একক কোনটি?', marks: 1),
        ]),
        composed(
          section(id: 's2', title: 'খ-বিভাগ: সৃজনশীল', type: QuestionType.cq),
          [q(id: 'c1', type: QuestionType.cq, body: 'ত্বরণ কাকে বলে?', marks: 10)],
        ),
      ];
      final sets = PaperComposer.compose(sections: sections, setCount: 2);

      final html = QuestionPaperDocument(engine: const DocumentEngine()).build(
        paper: paper,
        sets: sets,
        subjectName: 'পদার্থবিজ্ঞান',
        className: 'নবম শ্রেণি',
        includeAnswerKey: true,
      );

      expect(html, contains('বেগের একক কোনটি?'));
      expect(html, contains('পদার্থবিজ্ঞান'));
      expect(html, contains('class="mcq"'), reason: 'two-column MCQ');
      expect(html, contains('break-inside: avoid'));
      expect(html, contains('answer-space'), reason: 'room to write for CQ');
      expect(html, contains('SET A'));
      expect(html, contains('SET B'));
      expect(html, contains('ANSWER KEY'));
      expect(html, contains('Full marks: 50'));
      expect(html, contains('Time: 2 hours'));
      // Bengali sub-question lettering needs a counter style, never ol@type.
      expect(html, contains('@counter-style bn-alpha'));
      expect(html, isNot(contains('<ol type=')));
    });

    test('a single-set paper carries no set badge', () {
      final sections = [
        composed(section(id: 's1'), [q(id: 'q1')]),
      ];
      final html = QuestionPaperDocument(engine: const DocumentEngine()).build(
        paper: paper,
        sets: PaperComposer.compose(sections: sections),
      );
      expect(html, isNot(contains('SET A')));
    });
  });
}
