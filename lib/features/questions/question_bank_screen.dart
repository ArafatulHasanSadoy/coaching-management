import 'package:drift/drift.dart'
    show BooleanExpressionOperators, OrderingTerm, Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';
import 'paper_composer_screen.dart';
import 'scan_questions_screen.dart';

/// The question bank, and the way into composing a paper.
class QuestionBankScreen extends ConsumerStatefulWidget {
  const QuestionBankScreen({super.key});

  @override
  ConsumerState<QuestionBankScreen> createState() => _QuestionBankScreenState();
}

class _QuestionBankScreenState extends ConsumerState<QuestionBankScreen> {
  String? _subjectId;

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(databaseProvider);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: const SectionAppBar(
          section: Section.questions,
          title: 'Questions',
          bottom: TabBar(
            tabs: [Tab(text: 'Bank'), Tab(text: 'Papers')],
          ),
        ),
        body: TabBarView(
          children: [
            _bank(db),
            const _PapersTab(),
          ],
        ),
      ),
    );
  }

  /// Loaded once rather than assigned inside a builder.
  ///
  /// The previous version set `_subjectId` during the subject FutureBuilder,
  /// which mutates state without scheduling a rebuild — so the surrounding
  /// widget still saw null and showed "add subjects first" while a subject was
  /// plainly selected in the dropdown above it.
  Future<List<Subject>>? _subjects;

  Future<List<Subject>> _loadSubjects(AppDatabase db) => (db.select(db.subjects)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .get();

  Widget _bank(AppDatabase db) {
    _subjects ??= _loadSubjects(db);

    return Scaffold(
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'scan',
            tooltip: 'Photograph a printed page',
            onPressed: _subjectId == null
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            ScanQuestionsScreen(subjectId: _subjectId!),
                      ),
                    ),
            child: const Icon(Icons.document_scanner_outlined),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            backgroundColor: Section.questions.colour,
            foregroundColor: Colors.white,
            heroTag: 'type',
            onPressed: _subjectId == null ? null : _addQuestion,
            icon: const Icon(Icons.add),
            label: const Text('Question'),
          ),
        ],
      ),
      body: FutureBuilder<List<Subject>>(
        future: _subjects,
        builder: (context, snapshot) {
          final subjects = snapshot.data;
          if (subjects == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (subjects.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Add subjects to a class first — questions belong to a '
                  'subject.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          // Safe here: scheduled after this frame rather than during it.
          if (_subjectId == null ||
              !subjects.any((s) => s.id == _subjectId)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _subjectId = subjects.first.id);
            });
          }

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: DropdownButtonFormField<String>(
                  initialValue:
                      subjects.any((s) => s.id == _subjectId) ? _subjectId : null,
                  items: [
                    for (final s in subjects)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => setState(() => _subjectId = v),
                  decoration: const InputDecoration(
                    labelText: 'Subject',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              Expanded(
                child: _subjectId == null
                    ? const Center(child: CircularProgressIndicator())
                    : StreamBuilder<List<Question>>(
                        stream: (db.select(db.questions)
                              ..where((t) =>
                                  t.subjectId.equals(_subjectId!) &
                                  t.deletedAt.isNull())
                              ..orderBy(
                                  [(t) => OrderingTerm.desc(t.createdAt)]))
                            .watch(),
                        builder: (context, questionSnap) {
                          final questions = questionSnap.data;
                          if (questions == null) {
                            return const Center(
                                child: CircularProgressIndicator());
                          }
                          if (questions.isEmpty) {
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.all(32),
                                child: Text(
                                  'No questions in this subject yet. Add them '
                                  'once and reuse them in every paper — the app '
                                  'tracks what each class has already seen.',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            );
                          }
                          return ListView.separated(
                            itemCount: questions.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final q = questions[i];
                              return ListTile(
                                title: Text(
                                  q.bodyHtml
                                      .replaceAll(RegExp(r'<[^>]*>'), ''),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text([
                                  q.type.name.toUpperCase(),
                                  q.difficulty.name,
                                  '${q.marks} mark(s)',
                                  if (q.useCount > 0) 'used ${q.useCount}×',
                                ].join(' · ')),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addQuestion() async {
    if (_subjectId == null) return;
    final body = TextEditingController();
    final marks = TextEditingController(text: '1');
    final options = [
      for (var i = 0; i < 4; i++) TextEditingController(),
    ];
    var type = QuestionType.mcq;
    var difficulty = Difficulty.medium;
    var correct = 0;

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
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('New question',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 14),
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
                const SizedBox(height: 12),
                TextField(
                  controller: body,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Question',
                    hintText: 'বেগের একক কোনটি?',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (type == QuestionType.mcq) ...[
                  const SizedBox(height: 12),
                  RadioGroup<int>(
                    groupValue: correct,
                    onChanged: (v) => setSheet(() => correct = v ?? 0),
                    child: Column(children: [
                      for (var i = 0; i < options.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Radio<int>(value: i),
                              Expanded(
                                child: TextField(
                                  controller: options[i],
                                  decoration: InputDecoration(
                                    labelText:
                                        'Option ${['ক', 'খ', 'গ', 'ঘ'][i]}',
                                    isDense: true,
                                    border: const OutlineInputBorder(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ]),
                  ),
                  Text(
                    'The selected option is the answer. It follows the question '
                    'when sets are shuffled.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: marks,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Marks',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<Difficulty>(
                        initialValue: difficulty,
                        items: const [
                          DropdownMenuItem(
                              value: Difficulty.easy, child: Text('Easy')),
                          DropdownMenuItem(
                              value: Difficulty.medium, child: Text('Medium')),
                          DropdownMenuItem(
                              value: Difficulty.hard, child: Text('Hard')),
                        ],
                        onChanged: (v) => setSheet(() => difficulty = v!),
                        decoration: const InputDecoration(
                          labelText: 'Difficulty',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Add to bank'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (saved != true || body.text.trim().isEmpty) return;
    final db = ref.read(databaseProvider);
    final filled =
        options.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();

    await db.into(db.questions).insert(
          QuestionsCompanion.insert(
            subjectId: _subjectId!,
            type: type,
            difficulty: difficulty,
            bodyHtml: body.text.trim(),
            deviceId: ref.read(deviceIdProvider),
            optionsJson: Value(
              '[${filled.map((o) => '"${o.replaceAll('"', r'\"')}"').join(',')}]',
            ),
            correctOption:
                Value(type == QuestionType.mcq && filled.isNotEmpty ? correct : null),
            marks: Value(int.tryParse(marks.text) ?? 1),
          ),
        );
  }
}

class _PapersTab extends ConsumerWidget {
  const _PapersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Section.questions.colour,
        foregroundColor: Colors.white,
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const PaperComposerScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Paper'),
      ),
      body: StreamBuilder<List<QuestionPaper>>(
        stream: (db.select(db.questionPapers)
              ..where((t) => t.deletedAt.isNull())
              ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
            .watch(),
        builder: (context, snapshot) {
          final papers = snapshot.data;
          if (papers == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (papers.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Compose a paper from the bank. The app numbers the questions, '
                  'lays out the columns, checks the marks add up, and can print '
                  'shuffled sets with matching answer keys.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: papers.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final paper = papers[i];
              return ListTile(
                title: Text(paper.title),
                subtitle: Text('${paper.fullMarks} marks · '
                    '${paper.durationMinutes} min · '
                    '${paper.setCount} set(s)'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PaperComposerScreen(paper: paper),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
