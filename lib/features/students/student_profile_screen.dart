import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/phone.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import 'student_actions.dart';
import 'student_photo.dart';

/// Everything about one student, in one place.
class StudentProfileScreen extends ConsumerStatefulWidget {
  const StudentProfileScreen({required this.studentId, super.key});

  final String studentId;

  @override
  ConsumerState<StudentProfileScreen> createState() =>
      _StudentProfileScreenState();
}

class _StudentProfileScreenState extends ConsumerState<StudentProfileScreen> {
  int _reloads = 0;
  void _refresh() => setState(() => _reloads++);

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(databaseProvider);
    final theme = Theme.of(context);
    final studentId = widget.studentId;

    return Scaffold(
      appBar: const SectionAppBar(section: Section.students, title: 'Student'),
      body: FutureBuilder<Student?>(
        key: ValueKey(_reloads),
        future: (db.select(db.students)..where((t) => t.id.equals(studentId)))
            .getSingleOrNull(),
        builder: (context, snapshot) {
          final s = snapshot.data;
          if (s == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Row(
                children: [
                  StudentPhoto(student: s, onChanged: _refresh),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.name, style: theme.textTheme.titleLarge),
                        Text(s.code, style: theme.textTheme.bodySmall),
                        if (s.nameAlt.isNotEmpty)
                          Text(s.nameAlt, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _Section(title: 'Guardian', rows: [
                ('Name', s.guardianName),
                ('Relation', s.guardianRelation),
                ('Phone', Phone.forDisplay(s.guardianPhone)),
              ]),
              _Section(title: 'Student', rows: [
                ('Phone', Phone.forDisplay(s.studentPhone)),
                ('School', s.school),
                ('Blood group', s.bloodGroup),
                ('Gender', s.gender?.name ?? ''),
                (
                  'Date of birth',
                  s.dateOfBirth == null ? '' : _date(s.dateOfBirth!)
                ),
                ('Address', s.address),
              ]),
              _Section(title: 'At the centre', rows: [
                ('Admitted', _date(s.admissionDate)),
                ('Status', s.status.name),
                ('Referred by', s.referredBy),
              ]),
              if (s.notes.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Notes', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 6),
                        Text(s.notes),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              StudentActions(student: s, onChanged: _refresh),
            ],
          );
        },
      ),
    );
  }

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows});

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final filled = rows.where((r) => r.$2.trim().isNotEmpty).toList();
    if (filled.isEmpty) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(title, style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final (label, value) in filled)
              ListTile(
                dense: true,
                title: Text(label),
                trailing: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(value, textAlign: TextAlign.end),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
