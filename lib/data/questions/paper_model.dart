import 'dart:convert';
import 'dart:math';

import '../db/database.dart';
import '../db/tables.dart';

/// A question as it appears on one paper, with its marks resolved.
class PaperItem {
  const PaperItem({
    required this.question,
    required this.marks,
    required this.options,
    this.correctOption,
  });

  final Question question;
  final int marks;

  /// MCQ choices in the order they will be printed for this set.
  final List<String> options;

  /// Index into [options] — recomputed per set, since shuffling moves it.
  final int? correctOption;
}

class ComposedSection {
  const ComposedSection({required this.section, required this.items});

  final PaperSection section;
  final List<PaperItem> items;

  int get totalMarks {
    if (section.answerAny > 0) {
      // "Answer any 5 of 8" is worth five questions, not eight.
      final sorted = [for (final i in items) i.marks]..sort((a, b) => b - a);
      return sorted.take(section.answerAny).fold(0, (a, b) => a + b);
    }
    return items.fold(0, (sum, i) => sum + i.marks);
  }
}

/// One printable variant of a paper.
class PaperSet {
  const PaperSet({required this.label, required this.sections});

  /// 'A', 'B', 'C' — printed in the header so invigilators can tell them apart.
  final String label;
  final List<ComposedSection> sections;

  int get totalMarks => sections.fold(0, (sum, s) => sum + s.totalMarks);

  /// question number → correct option letter, for the answer key.
  Map<String, String> get answerKey {
    final key = <String, String>{};
    var number = 1;
    for (final section in sections) {
      for (final item in section.items) {
        if (item.question.type == QuestionType.mcq &&
            item.correctOption != null) {
          key['$number'] = String.fromCharCode(65 + item.correctOption!);
        }
        number++;
      }
    }
    return key;
  }
}

/// Whether the marks on the page add up to what the header claims.
///
/// Cheap to compute and catches a genuinely embarrassing mistake: a paper
/// printed for a whole class saying "Full marks 50" whose questions total 47.
class MarksCheck {
  const MarksCheck({required this.declared, required this.actual});

  final int declared;
  final int actual;

  bool get matches => declared == actual;
  int get difference => actual - declared;

  String? get warning {
    if (matches) return null;
    return difference > 0
        ? 'The questions add up to $actual, but full marks says $declared — '
            '$difference too many.'
        : 'The questions add up to $actual, but full marks says $declared — '
            '${-difference} short.';
  }
}

/// A rule for picking questions automatically: "ten MCQ from chapters 1–3,
/// mixed difficulty".
class BlueprintRule {
  const BlueprintRule({
    required this.type,
    required this.count,
    this.chapterIds = const [],
    this.difficulty,
    this.marksEach,
  });

  final QuestionType type;
  final int count;
  final List<String> chapterIds;
  final Difficulty? difficulty;
  final int? marksEach;
}

/// Picks questions from the bank to satisfy a set of rules.
///
/// Prefers questions that have not been used recently, so a class does not sit
/// the same paper twice in a year — the reason `lastUsedAt` and `useCount`
/// exist on every question.
abstract final class Blueprint {
  static List<Question> select({
    required List<Question> pool,
    required BlueprintRule rule,
    int seed = 20260910,
    DateTime? now,
  }) {
    final today = now ?? DateTime.now();
    var candidates = pool.where((q) => q.type == rule.type).toList();

    if (rule.chapterIds.isNotEmpty) {
      candidates = candidates
          .where((q) => q.chapterId != null && rule.chapterIds.contains(q.chapterId))
          .toList();
    }
    if (rule.difficulty != null) {
      candidates =
          candidates.where((q) => q.difficulty == rule.difficulty).toList();
    }

    // Least recently used first; never used counts as longest ago.
    candidates.sort((a, b) {
      final aDays = a.lastUsedAt == null
          ? 1 << 30
          : today.difference(a.lastUsedAt!).inDays;
      final bDays = b.lastUsedAt == null
          ? 1 << 30
          : today.difference(b.lastUsedAt!).inDays;
      if (aDays != bDays) return bDays.compareTo(aDays);
      return a.useCount.compareTo(b.useCount);
    });

    // Shuffle within equally-stale groups so it is not the same order forever.
    final random = Random(seed);
    final chosen = candidates.take(rule.count).toList()..shuffle(random);
    return chosen;
  }
}

/// Produces the printable variants of a paper.
abstract final class PaperComposer {
  static List<String> optionsOf(Question question) {
    try {
      final raw = jsonDecode(question.optionsJson);
      return raw is List ? raw.map((o) => '$o').toList() : const [];
    } catch (_) {
      return const [];
    }
  }

  /// Builds [setCount] variants.
  ///
  /// Set A is always the paper as composed. Later sets shuffle question order
  /// within a section and the options within each MCQ, tracking where the right
  /// answer moved so the key stays correct — a shuffled paper with the original
  /// key is worse than no shuffling at all.
  static List<PaperSet> compose({
    required List<ComposedSection> sections,
    int setCount = 1,
    int seed = 20260910,
  }) {
    final sets = <PaperSet>[];

    for (var s = 0; s < setCount; s++) {
      final label = String.fromCharCode(65 + s);
      if (s == 0) {
        sets.add(PaperSet(label: label, sections: sections));
        continue;
      }

      final random = Random(seed + s);
      sets.add(
        PaperSet(
          label: label,
          sections: [
            for (final section in sections)
              ComposedSection(
                section: section.section,
                items: ([...section.items]..shuffle(random))
                    .map((item) => _shuffleOptions(item, random))
                    .toList(),
              ),
          ],
        ),
      );
    }
    return sets;
  }

  static PaperItem _shuffleOptions(PaperItem item, Random random) {
    if (item.question.type != QuestionType.mcq || item.options.length < 2) {
      return item;
    }

    final indexed = [
      for (var i = 0; i < item.options.length; i++) (i, item.options[i]),
    ]..shuffle(random);

    final moved = item.correctOption == null
        ? null
        : indexed.indexWhere((e) => e.$1 == item.correctOption);

    return PaperItem(
      question: item.question,
      marks: item.marks,
      options: [for (final e in indexed) e.$2],
      correctOption: moved != null && moved >= 0 ? moved : null,
    );
  }

  static MarksCheck check({
    required List<ComposedSection> sections,
    required int fullMarks,
  }) =>
      MarksCheck(
        declared: fullMarks,
        actual: sections.fold(0, (sum, s) => sum + s.totalMarks),
      );
}
