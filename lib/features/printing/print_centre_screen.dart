import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../app/lock_controller.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';
import '../../data/printing/id_card_document.dart';
import '../../data/printing/print_centre_service.dart';

/// Everything the centre puts on paper.
///
/// Two kinds of thing live here: the fixed forms an owner already has as a PDF
/// and reprints forever, and the layouts the app fills in from the database.
/// Both end up at the same printer, so they belong on the same screen.
class PrintCentreScreen extends ConsumerStatefulWidget {
  const PrintCentreScreen({super.key});

  @override
  ConsumerState<PrintCentreScreen> createState() => _PrintCentreScreenState();
}

class _PrintCentreScreenState extends ConsumerState<PrintCentreScreen> {
  int _reloads = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = ref.watch(printCentreProvider);

    return Scaffold(
      appBar: const SectionAppBar(section: Section.printing, title: 'Print centre'),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Section.printing.colour,
        foregroundColor: Colors.white,
        onPressed: _upload,
        icon: const Icon(Icons.upload_file),
        label: const Text('Upload a form'),
      ),
      body: ListView(
        key: ValueKey(_reloads),
        children: [
          FutureBuilder<List<DuePrint>>(
            future: service.dueNow(),
            builder: (context, snapshot) {
              final due = snapshot.data ?? const <DuePrint>[];
              if (due.isEmpty) return const SizedBox.shrink();
              return Container(
                color: theme.colorScheme.errorContainer,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Needs printing',
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    for (final item in due)
                      Text('${item.template.name} — ${item.reason}'),
                  ],
                ),
              );
            },
          ),

          const _Heading('Ready to print'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('Student ID cards'),
                  subtitle: const Text('Filled from the register, four to a page'),
                  trailing: const Icon(Icons.print_outlined),
                  onTap: _printIdCards,
                ),
              ],
            ),
          ),

          const _Heading('Your own forms'),
          StreamBuilder<List<PrintTemplate>>(
            stream: service.watchTemplates(),
            builder: (context, snapshot) {
              final templates = snapshot.data;
              if (templates == null) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (templates.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Upload the pages you already print — the diary sheet, a '
                    'blank attendance register, your notice paper. Set when '
                    'they are needed and the app will remind you.',
                    textAlign: TextAlign.center,
                  ),
                );
              }
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    for (final template in templates)
                      ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: Text(template.name),
                        subtitle: Text(_cadenceLabel(template)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.print_outlined),
                              tooltip: 'Print',
                              onPressed: () => _printTemplate(template),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (choice) => switch (choice) {
                                'when' => _editCadence(template),
                                'remove' => _archive(template),
                                _ => null,
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                    value: 'when', child: Text('When it is needed')),
                                PopupMenuItem(
                                    value: 'remove', child: Text('Remove')),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          ),

          const _Heading('Recently printed'),
          FutureBuilder<List<PrintJob>>(
            future: service.history(limit: 10),
            builder: (context, snapshot) {
              final jobs = snapshot.data ?? const <PrintJob>[];
              if (jobs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('Nothing printed yet.',
                      textAlign: TextAlign.center),
                );
              }
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    for (final job in jobs)
                      ListTile(
                        dense: true,
                        title: Text(job.title),
                        subtitle: Text('${job.copies} copy(ies) · '
                            '${job.printedAt.day}/${job.printedAt.month}/'
                            '${job.printedAt.year}'),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static String _cadenceLabel(PrintTemplate t) => switch (t.cadence) {
        PrintCadence.onDemand => 'When you need it',
        PrintCadence.weekly => 'Every week',
        PrintCadence.monthlyOnDays =>
          'Every month on day ${t.cadenceDays.split(',').join(' and ')}',
      };

  Future<void> _upload() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Choose a PDF or image',
      type: FileType.any,
    );
    final path = picked?.path;
    if (path == null || !mounted) return;

    final name = TextEditingController(
      text: picked!.name.replaceAll(RegExp(r'\.[^.]+$'), ''),
    );
    final copies = TextEditingController(text: '1');
    var cadence = PrintCadence.monthlyOnDays;
    final days = <int>{1, 16};

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
                Text('New form',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 14),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'What is it',
                    hintText: 'Diary page',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('When do you need it?'),
                const SizedBox(height: 8),
                SegmentedButton<PrintCadence>(
                  segments: const [
                    ButtonSegment(
                        value: PrintCadence.onDemand, label: Text('When asked')),
                    ButtonSegment(
                        value: PrintCadence.weekly, label: Text('Weekly')),
                    ButtonSegment(
                        value: PrintCadence.monthlyOnDays,
                        label: Text('Set days')),
                  ],
                  selected: {cadence},
                  onSelectionChanged: (v) => setSheet(() => cadence = v.first),
                ),
                if (cadence == PrintCadence.monthlyOnDays) ...[
                  const SizedBox(height: 12),
                  const Text('Days of the month'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final day in [1, 5, 10, 15, 16, 20, 25, 28])
                        FilterChip(
                          label: Text('$day'),
                          selected: days.contains(day),
                          onSelected: (on) => setSheet(() {
                            on ? days.add(day) : days.remove(day);
                          }),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                TextField(
                  controller: copies,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'How many copies, usually',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved != true || name.text.trim().isEmpty) return;

    final paths = await ref.read(appPathsProvider.future);
    await ref.read(printCentreProvider).addFixedFile(
          name: name.text,
          source: File(path),
          mediaDir: paths.mediaDir,
          cadence: cadence,
          days: days.toList()..sort(),
          copies: int.tryParse(copies.text) ?? 1,
        );
    setState(() => _reloads++);
  }

  Future<void> _printTemplate(PrintTemplate template) async {
    final path = template.filePath;
    if (path == null || !File(path).existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That file is missing — upload it again.'),
        ),
      );
      return;
    }

    await ref
        .read(documentEngineProvider)
        .printPdfFile(path, jobName: template.name);

    await ref.read(printCentreProvider).recordPrinted(
          template,
          by: ref.read(currentUserProvider)?.name ?? '',
        );
    if (mounted) setState(() => _reloads++);
  }

  Future<void> _editCadence(PrintTemplate template) async {
    var cadence = template.cadence;
    final days = template.cadenceDays
        .split(',')
        .map((d) => int.tryParse(d.trim()))
        .whereType<int>()
        .toSet();

    final saved = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('When is ${template.name} needed?',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 14),
              SegmentedButton<PrintCadence>(
                segments: const [
                  ButtonSegment(
                      value: PrintCadence.onDemand, label: Text('When asked')),
                  ButtonSegment(
                      value: PrintCadence.weekly, label: Text('Weekly')),
                  ButtonSegment(
                      value: PrintCadence.monthlyOnDays, label: Text('Set days')),
                ],
                selected: {cadence},
                onSelectionChanged: (v) => setSheet(() => cadence = v.first),
              ),
              if (cadence == PrintCadence.monthlyOnDays) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final day in [1, 5, 10, 15, 16, 20, 25, 28])
                      FilterChip(
                        label: Text('$day'),
                        selected: days.contains(day),
                        onSelected: (on) => setSheet(() {
                          on ? days.add(day) : days.remove(day);
                        }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved != true) return;

    await ref.read(printCentreProvider).updateCadence(
          template,
          cadence: cadence,
          days: days.toList()..sort(),
        );
    setState(() => _reloads++);
  }

  Future<void> _archive(PrintTemplate template) async {
    await ref.read(printCentreProvider).archive(template);
    setState(() => _reloads++);
  }

  Future<void> _printIdCards() async {
    final session = await ref.read(activeSessionProvider.future);
    if (session == null || !mounted) return;

    final batches =
        await ref.read(masterDataProvider).watchBatches(session.id).first;
    if (!mounted) return;

    final batch = await showDialog<StudentBatch>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Cards for which batch?'),
        children: [
          for (final b in batches)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, b),
              child: Text(b.name),
            ),
        ],
      ),
    );
    if (batch == null) return;

    final students =
        await ref.read(studentsProvider).watchBatchRoster(batch.id).first;
    if (students.isEmpty || !mounted) return;

    final institution = ref.read(institutionProvider).value;
    final engine = ref.read(documentEngineProvider);
    final html = IdCardDocument(engine: engine).build(
      students: students,
      centreName: institution?.name ?? '',
      centrePhone: institution?.phone ?? '',
      batchNames: {for (final s in students) s.id: batch.name},
    );

    await engine.printDocument(html, jobName: 'ID cards — ${batch.name}');
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 1,
              ),
        ),
      );
}
