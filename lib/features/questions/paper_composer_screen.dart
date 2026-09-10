import 'package:drift/drift.dart'
    show BooleanExpressionOperators, OrderingTerm, Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';
import '../../data/questions/paper_model.dart';
import '../../data/questions/question_paper_document.dart';

/// Builds a question paper out of the bank.
///
/// The teacher supplies the questions; everything a teacher currently does by
/// hand in Word — numbering, columns, spacing, page breaks, checking the marks
/// add up — is the app's job.
class PaperComposerScreen extends ConsumerStatefulWidget {
  const PaperComposerScreen({this.paper, super.key});

  final QuestionPaper? paper;

  @override
  ConsumerState<PaperComposerScreen> createState() =>
      _PaperComposerScreenState();
}

class _PaperComposerScreenState extends ConsumerState<PaperComposerScreen> {
  QuestionPaper? _paper;
  List<ComposedSection> _sections = [];
  bool _busy = false;

  final _title = TextEditingController();
  final _fullMarks = TextEditingController(text: '50');
  final _duration = TextEditingController(text: '120');
  int _setCount = 1;
  String? _subjectId;

  @override
  void initState() {
    super.initState();
    _paper = widget.paper;
    if (_paper != null) {
      _title.text = _paper!.title;
      _fullMarks.text = '${_paper!.fullMarks}';
      _duration.text = '${_paper!.durationMinutes}';
      _setCount = _paper!.setCount;
      _subjectId = _paper!.subjectId;
      _reloadSections();
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _fullMarks.dispose();
    _duration.dispose();
    super.dispose();
  }

  Future<void> _reloadSections() async {
    final db = ref.read(databaseProvider);
    final sections = await (db.select(db.paperSections)
          ..where((t) =>
              t.paperId.equals(_paper!.id) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();

    final composed = <ComposedSection>[];
    for (final section in sections) {
      final links = await (db.select(db.paperQuestions)
            ..where((t) =>
                t.sectionId.equals(section.id) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get();

      final items = <PaperItem>[];
      for (final link in links) {
        final question = await (db.select(db.questions)
              ..where((t) => t.id.equals(link.questionId)))
            .getSingleOrNull();
        if (question == null) continue;
        items.add(
          PaperItem(
            question: question,
            marks: link.marksOverride ?? question.marks,
            options: PaperComposer.optionsOf(question),
            correctOption: question.correctOption,
          ),
        );
      }
      composed.add(ComposedSection(section: section, items: items));
    }

    if (mounted) setState(() => _sections = composed);
  }

  Future<void> _savePaper() async {
    final db = ref.read(databaseProvider);
    final deviceId = ref.read(deviceIdProvider);

    if (_paper == null) {
      final row = await db.into(db.questionPapers).insertReturning(
            QuestionPapersCompanion.insert(
              title: _title.text.trim(),
              deviceId: deviceId,
              subjectId: Value(_subjectId),
              fullMarks: Value(int.tryParse(_fullMarks.text) ?? 50),
              durationMinutes: Value(int.tryParse(_duration.text) ?? 120),
              setCount: Value(_setCount),
            ),
          );
      setState(() => _paper = row);
    } else {
      await (db.update(db.questionPapers)
            ..where((t) => t.id.equals(_paper!.id)))
          .write(
        QuestionPapersCompanion(
          title: Value(_title.text.trim()),
          subjectId: Value(_subjectId),
          fullMarks: Value(int.tryParse(_fullMarks.text) ?? 50),
          durationMinutes: Value(int.tryParse(_duration.text) ?? 120),
          setCount: Value(_setCount),
          updatedAt: Value(DateTime.now()),
        ),
      );
      final refreshed = await (db.select(db.questionPapers)
            ..where((t) => t.id.equals(_paper!.id)))
          .getSingle();
      setState(() => _paper = refreshed);
    }
  }

  Future<void> _addSection() async {
    if (_paper == null) await _savePaper();
    if (!mounted) return;
    final title = TextEditingController(text: 'ক-বিভাগ');
    var type = QuestionType.mcq;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Add a section',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 14),
              TextField(
                controller: title,
                decoration: const InputDecoration(
                  labelText: 'Section title',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<QuestionType>(
                segments: const [
                  ButtonSegment(value: QuestionType.mcq, label: Text('MCQ')),
                  ButtonSegment(value: QuestionType.cq, label: Text('CQ')),
                  ButtonSegment(
                      value: QuestionType.short, label: Text('Short')),
                ],
                selected: {type},
                onSelectionChanged: (v) => setSheet(() => type = v.first),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Add'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved != true) return;

    final db = ref.read(databaseProvider);
    await db.into(db.paperSections).insert(
          PaperSectionsCompanion.insert(
            paperId: _paper!.id,
            title: title.text.trim(),
            type: type,
            deviceId: ref.read(deviceIdProvider),
            sortOrder: Value(_sections.length),
          ),
        );
    await _reloadSections();
  }

  /// Fills a section straight from the bank.
  Future<void> _autoFill(ComposedSection section) async {
    final db = ref.read(databaseProvider);
    final count = TextEditingController(text: '10');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Fill ${section.section.title}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Takes questions of this type from the bank, preferring ones the '
              'class has not seen recently.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: count,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'How many',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Fill'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final query = db.select(db.questions)
      ..where((t) => t.deletedAt.isNull());
    if (_subjectId != null) {
      query.where((t) => t.subjectId.equals(_subjectId!));
    }
    final pool = await query.get();

    final chosen = Blueprint.select(
      pool: pool,
      rule: BlueprintRule(
        type: section.section.type,
        count: int.tryParse(count.text) ?? 10,
      ),
    );

    final deviceId = ref.read(deviceIdProvider);
    await db.transaction(() async {
      for (var i = 0; i < chosen.length; i++) {
        await db.into(db.paperQuestions).insert(
              PaperQuestionsCompanion.insert(
                sectionId: section.section.id,
                questionId: chosen[i].id,
                deviceId: deviceId,
                sortOrder: Value(section.items.length + i),
              ),
            );
        await (db.update(db.questions)
              ..where((t) => t.id.equals(chosen[i].id)))
            .write(
          QuestionsCompanion(
            lastUsedAt: Value(DateTime.now()),
            useCount: Value(chosen[i].useCount + 1),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }
    });
    await _reloadSections();
  }

  Future<void> _print({bool withKey = false}) async {
    setState(() => _busy = true);
    try {
      await _savePaper();
      final engine = ref.read(documentEngineProvider);
      final sets = PaperComposer.compose(
        sections: _sections,
        setCount: _setCount,
      );

      final html = QuestionPaperDocument(engine: engine).build(
        paper: _paper!,
        sets: sets,
        includeAnswerKey: withKey,
      );
      await engine.printDocument(html, jobName: _paper!.title);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final check = PaperComposer.check(
      sections: _sections,
      fullMarks: int.tryParse(_fullMarks.text) ?? 0,
    );

    return Scaffold(
      appBar: SectionAppBar(
        section: Section.questions,
        title: _paper == null ? 'New paper' : 'Paper',
        actions: [
          IconButton(
            tooltip: 'Print',
            icon: const Icon(Icons.print_outlined),
            onPressed: _sections.isEmpty || _busy ? null : () => _print(),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'key') _print(withKey: true);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'key',
                child: Text('Print with answer key'),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _title,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Paper title',
              hintText: 'প্রথম সাময়িক পরীক্ষা — ২০২৬',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _fullMarks,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Full marks',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _duration,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Minutes',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('Sets to print'),
              const Spacer(),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('1')),
                  ButtonSegment(value: 2, label: Text('2')),
                  ButtonSegment(value: 3, label: Text('3')),
                  ButtonSegment(value: 4, label: Text('4')),
                ],
                selected: {_setCount},
                onSelectionChanged: (v) => setState(() => _setCount = v.first),
              ),
            ],
          ),
          if (_setCount > 1)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Each set shuffles the questions and the options, and its '
                'answer key follows the shuffle.',
                style: theme.textTheme.bodySmall,
              ),
            ),

          const SizedBox(height: 20),
          if (_sections.isNotEmpty)
            Card(
              color: check.matches
                  ? theme.colorScheme.secondaryContainer
                  : theme.colorScheme.errorContainer,
              child: ListTile(
                leading: Icon(
                  check.matches ? Icons.check_circle_outline : Icons.warning_amber,
                ),
                title: Text(check.matches
                    ? 'Marks add up to ${check.actual}'
                    : 'Marks do not add up'),
                subtitle: check.warning == null ? null : Text(check.warning!),
              ),
            ),

          const SizedBox(height: 12),
          for (final section in _sections)
            Card(
              child: Column(
                children: [
                  ListTile(
                    title: Text(section.section.title),
                    subtitle: Text('${section.items.length} question(s) · '
                        '${section.totalMarks} marks'),
                    trailing: TextButton.icon(
                      onPressed: () => _autoFill(section),
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: const Text('Fill'),
                    ),
                  ),
                  for (var i = 0; i < section.items.length; i++)
                    ListTile(
                      dense: true,
                      leading: Text('${i + 1}'),
                      title: Text(
                        section.items[i].question.bodyHtml
                            .replaceAll(RegExp(r'<[^>]*>'), ''),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text('${section.items[i].marks}'),
                    ),
                ],
              ),
            ),

          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _title.text.trim().isEmpty ? null : _addSection,
            icon: const Icon(Icons.add),
            label: const Text('Add a section'),
          ),
        ],
      ),
    );
  }
}
