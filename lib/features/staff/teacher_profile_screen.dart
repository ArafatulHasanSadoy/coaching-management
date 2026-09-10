import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/phone.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/staff/staff_repository.dart';
import 'staff_screen.dart';

/// Everything about one teacher in one place.
///
/// Tapping a name should answer the questions that follow it: how do I reach
/// them, what do they take, how much have they taught, what have we paid them.
/// Scattering those across four screens is how an owner ends up keeping a
/// notebook alongside the app.
class TeacherProfileScreen extends ConsumerStatefulWidget {
  const TeacherProfileScreen({required this.staffId, super.key});

  final String staffId;

  @override
  ConsumerState<TeacherProfileScreen> createState() =>
      _TeacherProfileScreenState();
}

class _TeacherProfileScreenState extends ConsumerState<TeacherProfileScreen> {
  int _reloads = 0;
  void _refresh() => setState(() => _reloads++);

  @override
  Widget build(BuildContext context) {
    const section = Section.teachers;
    final db = ref.watch(databaseProvider);
    final repo = ref.watch(staffRepositoryProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: const SectionAppBar(section: section, title: 'Teacher'),
      body: FutureBuilder<StaffMember?>(
        key: ValueKey(_reloads),
        future: (db.select(db.staff)..where((t) => t.id.equals(widget.staffId)))
            .getSingleOrNull(),
        builder: (context, snapshot) {
          final member = snapshot.data;
          if (member == null) {
            return const Center(child: CircularProgressIndicator());
          }

          return FutureBuilder<TeacherProfile>(
            future: repo.profileOf(member),
            builder: (context, profileSnap) {
              final profile = profileSnap.data;
              if (profile == null) {
                return const Center(child: CircularProgressIndicator());
              }

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  Card(
                    elevation: 0,
                    color: section.tint(context),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 28,
                            backgroundColor: section.band(context),
                            foregroundColor: section.onTint(context),
                            child: Text(member.name.characters.first,
                                style: theme.textTheme.titleLarge),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(member.name,
                                    style: theme.textTheme.titleLarge),
                                Text(member.role,
                                    style: theme.textTheme.bodySmall),
                                if (member.phone.isNotEmpty)
                                  Text(Phone.forDisplay(member.phone),
                                      style: theme.textTheme.bodyMedium),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: 'Edit',
                            onPressed: () => _edit(member),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _Stat(
                        section: section,
                        label: 'Classes this month',
                        value: '${profile.classesTaughtThisMonth}',
                      ),
                      const SizedBox(width: 12),
                      _Stat(
                        section: section,
                        label: 'Paid to date',
                        value: '৳${profile.paidToDate}',
                      ),
                    ],
                  ),

                  const SectionHeading('Classes taken', section: section),
                  Card(
                    elevation: 0,
                    child: Column(
                      children: [
                        if (profile.classes.isEmpty)
                          const ListTile(
                            dense: true,
                            title: Text('No classes assigned yet'),
                            subtitle: Text(
                              'The routine builder uses this to know who can '
                              'teach what.',
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                for (final c in profile.classes)
                                  Chip(label: Text(c.name)),
                              ],
                            ),
                          ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.edit_outlined),
                          title: const Text('Choose classes'),
                          onTap: () => _chooseClasses(member, profile),
                        ),
                      ],
                    ),
                  ),

                  const SectionHeading('Subjects', section: section),
                  Card(
                    elevation: 0,
                    child: Column(
                      children: [
                        if (profile.subjects.isEmpty)
                          const ListTile(
                            dense: true,
                            title: Text('No subjects assigned yet'),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                for (final s in profile.subjects)
                                  Chip(label: Text(s.name)),
                              ],
                            ),
                          ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.edit_outlined),
                          title: const Text('Choose subjects'),
                          onTap: () => _chooseSubjects(member, profile),
                        ),
                      ],
                    ),
                  ),

                  const SectionHeading('Payments', section: Section.money),
                  Card(
                    elevation: 0,
                    child: profile.recentPayments.isEmpty
                        ? const ListTile(
                            dense: true,
                            title: Text('Nothing paid yet'),
                          )
                        : Column(
                            children: [
                              for (final p in profile.recentPayments)
                                ListTile(
                                  dense: true,
                                  leading: const Icon(
                                      Icons.receipt_long_outlined),
                                  title: Text(p.periodKey),
                                  subtitle: Text(
                                    '${p.paidOn.day}/${p.paidOn.month}/'
                                    '${p.paidOn.year}',
                                  ),
                                  trailing: Text('৳${p.netAmount}'),
                                ),
                            ],
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _edit(StaffMember member) async {
    final result = await showStaffSheet(
      context: context,
      isTeacher: member.isTeacher,
      existing: member,
    );
    if (result == null) return;

    await ref.read(staffRepositoryProvider).update(
          member,
          name: result.name,
          phone: result.phone,
          role: result.role,
          payModel: result.payModel,
          monthlySalary: result.monthlySalary,
          perClassRate: result.perClassRate,
          hourlyRate: result.hourlyRate,
        );
    _refresh();
  }

  Future<void> _chooseClasses(
      StaffMember member, TeacherProfile profile) async {
    final all = await ref.read(masterDataProvider).watchClasses().first;
    if (!mounted) return;
    final chosen = await _multiPick(
      title: 'Which classes does ${member.name} take?',
      items: [for (final c in all) (c.id, c.name)],
      selected: profile.classes.map((c) => c.id).toSet(),
    );
    if (chosen == null) return;
    await ref.read(staffRepositoryProvider).setClasses(member.id, chosen);
    _refresh();
  }

  Future<void> _chooseSubjects(
      StaffMember member, TeacherProfile profile) async {
    final db = ref.read(databaseProvider);
    final all = await (db.select(db.subjects)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    if (!mounted) return;
    final chosen = await _multiPick(
      title: 'Which subjects does ${member.name} teach?',
      items: [for (final s in all) (s.id, s.name)],
      selected: profile.subjects.map((s) => s.id).toSet(),
    );
    if (chosen == null) return;
    await ref.read(staffRepositoryProvider).setSubjects(member.id, chosen);
    _refresh();
  }

  Future<List<String>?> _multiPick({
    required String title,
    required List<(String, String)> items,
    required Set<String> selected,
  }) {
    final picked = {...selected};
    return showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (context, controller) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(title,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              Expanded(
                child: items.isEmpty
                    ? const Center(child: Text('Nothing to choose from yet.'))
                    : ListView(
                        controller: controller,
                        children: [
                          for (final (id, label) in items)
                            CheckboxListTile(
                              value: picked.contains(id),
                              onChanged: (on) => setSheet(() {
                                on ?? false ? picked.add(id) : picked.remove(id);
                              }),
                              title: Text(label),
                            ),
                        ],
                      ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, picked.toList()),
                      child: const Text('Save'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.section,
    required this.label,
    required this.value,
  });

  final Section section;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Card(
        elevation: 0,
        color: section.tint(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Column(
            children: [
              Text(value,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(color: section.onTint(context))),
              const SizedBox(height: 2),
              Text(label, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
