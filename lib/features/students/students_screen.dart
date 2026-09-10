import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/phone.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import 'admission_screen.dart';
import 'import_screen.dart';
import 'student_profile_screen.dart';

/// The register, grouped the way a centre thinks about it.
///
/// Six hundred names in one alphabetical list is not how anyone holds a centre
/// in their head — they think in classes. Search still cuts across everything,
/// because when a guardian rings, the class is the last thing anyone knows.
class StudentsScreen extends ConsumerStatefulWidget {
  const StudentsScreen({super.key});

  @override
  ConsumerState<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends ConsumerState<StudentsScreen> {
  final _query = TextEditingController();
  List<Student>? _results;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search(String value) async {
    if (value.trim().isEmpty) {
      setState(() => _results = null);
      return;
    }
    final found = await ref.read(studentsProvider).search(value);
    if (mounted) setState(() => _results = found);
  }

  @override
  Widget build(BuildContext context) {
    const section = Section.students;
    final session = ref.watch(activeSessionProvider).value;

    return Scaffold(
      appBar: SectionAppBar(
        section: section,
        title: 'Students',
        actions: [
          IconButton(
            tooltip: 'Add a class',
            icon: const Icon(Icons.playlist_add),
            onPressed: _addClass,
          ),
          IconButton(
            tooltip: 'Import a register',
            icon: const Icon(Icons.upload_file),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ImportScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: section.band(context),
        foregroundColor: section.onTint(context),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const AdmissionScreen()),
        ),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Admit'),
      ),
      body: Column(
        children: [
          Container(
            color: section.tint(context),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: TextField(
              controller: _query,
              onChanged: _search,
              decoration: InputDecoration(
                // Phone first, because when a guardian rings that is all the
                // desk has to go on.
                hintText: 'Phone number, name or ID',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                border: const OutlineInputBorder(),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _query.clear();
                          _search('');
                        },
                      ),
              ),
            ),
          ),
          Expanded(
            child: _results != null
                ? _searchResults(_results!)
                : session == null
                    ? const Center(child: CircularProgressIndicator())
                    : StreamBuilder<Map<SchoolClass?, List<Student>>>(
                        stream: ref
                            .watch(studentsProvider)
                            .watchByClass(session.id),
                        builder: (context, snapshot) {
                          final grouped = snapshot.data;
                          if (grouped == null) {
                            return const Center(
                                child: CircularProgressIndicator());
                          }
                          if (grouped.isEmpty) return _empty();
                          return _grouped(grouped);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _empty() => EmptyState(
        section: Section.students,
        title: 'No students yet',
        body: 'Admit them one at a time, or import the register you already '
            'keep as a spreadsheet.',
        action: FilledButton.tonalIcon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ImportScreen()),
          ),
          icon: const Icon(Icons.upload_file),
          label: const Text('Import a register'),
        ),
      );

  Widget _grouped(Map<SchoolClass?, List<Student>> grouped) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        for (final entry in grouped.entries)
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: grouped.length <= 3,
              collapsedBackgroundColor: Section.students.tint(context),
              backgroundColor: Section.students.tint(context),
              leading: Icon(
                entry.key == null ? Icons.help_outline : Icons.class_outlined,
                color: Section.students.onTint(context),
              ),
              title: Text(
                // A student in no batch is not an error to hide — it is the
                // one the office most needs to notice.
                entry.key?.name ?? 'Not in any batch',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('${entry.value.length} student(s)'),
              children: [
                for (final student in entry.value) _row(student),
              ],
            ),
          ),
      ],
    );
  }

  Widget _searchResults(List<Student> students) {
    if (students.isEmpty) {
      return const EmptyState(
        section: Section.students,
        title: 'Nobody matches that',
        body: 'Try part of a name, or the guardian’s phone number.',
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [for (final s in students) _row(s)],
    );
  }

  Widget _row(Student s) => ListTile(
        tileColor: Theme.of(context).colorScheme.surface,
        leading: CircleAvatar(
          backgroundColor: Section.students.tint(context),
          foregroundColor: Section.students.onTint(context),
          child: Text(
            s.name.characters.isEmpty ? '?' : s.name.characters.first,
          ),
        ),
        title: Text(s.name),
        subtitle: Text([
          s.code,
          if (s.guardianPhone.isNotEmpty) Phone.forDisplay(s.guardianPhone),
        ].join(' · ')),
        trailing: s.monthlyFee > 0
            ? Text('৳${s.monthlyFee}',
                style: Theme.of(context).textTheme.labelMedium)
            : null,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => StudentProfileScreen(studentId: s.id),
          ),
        ),
      );

  /// Adding a class without leaving the register.
  ///
  /// The owner is looking at their students when they realise a class is
  /// missing; sending them to a settings screen to fix that loses their place.
  Future<void> _addClass() async {
    final name = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a class'),
        content: TextField(
          controller: name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Class name',
            hintText: 'Class 9 — Science',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (saved != true || name.text.trim().isEmpty) return;

    await ref.read(masterDataProvider).addClass(name.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${name.text.trim()} added. Create a batch in it to '
            'admit students.'),
      ),
    );
  }
}
