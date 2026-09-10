import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/phone.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';
import 'staff_attendance_screen.dart';
import 'teacher_profile_screen.dart';

/// Teachers and office staff, kept apart.
///
/// They answer different questions. A teacher has classes, subjects and pay
/// that depends on how much they taught; an office worker has a job and a
/// salary. One combined list makes both harder to read.
class StaffScreen extends ConsumerWidget {
  const StaffScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const section = Section.teachers;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: SectionAppBar(
          section: section,
          title: 'Teachers and staff',
          actions: [
            IconButton(
              tooltip: 'Attendance',
              icon: const Icon(Icons.fact_check_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const StaffAttendanceScreen(),
                ),
              ),
            ),
          ],
          bottom: const TabBar(
            tabs: [Tab(text: 'Teachers'), Tab(text: 'Other staff')],
          ),
        ),
        body: const TabBarView(
          children: [
            _PeopleList(teachers: true),
            _PeopleList(teachers: false),
          ],
        ),
      ),
    );
  }
}

class _PeopleList extends ConsumerWidget {
  const _PeopleList({required this.teachers});
  final bool teachers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const section = Section.teachers;
    final repo = ref.watch(staffRepositoryProvider);
    final theme = Theme.of(context);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: teachers ? 'add-teacher' : 'add-staff',
        backgroundColor: section.band(context),
        foregroundColor: section.onTint(context),
        onPressed: () => _add(context, ref),
        icon: const Icon(Icons.person_add_alt),
        label: Text(teachers ? 'Teacher' : 'Staff'),
      ),
      body: StreamBuilder<List<StaffMember>>(
        stream: teachers ? repo.watchTeachers() : repo.watchOtherStaff(),
        builder: (context, snapshot) {
          final people = snapshot.data;
          if (people == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (people.isEmpty) {
            return EmptyState(
              section: section,
              title: teachers ? 'No teachers yet' : 'No other staff yet',
              body: teachers
                  ? 'Add them here. The routine builder and per-class pay both '
                      'work from this list.'
                  : 'Accounts, reception, caretaking — anyone who is paid but '
                      'does not teach.',
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: people.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
            itemBuilder: (context, i) {
              final person = people[i];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: section.tint(context),
                  foregroundColor: section.onTint(context),
                  child: Text(person.name.characters.first),
                ),
                title: Text(person.name),
                subtitle: Text([
                  person.role,
                  if (person.phone.isNotEmpty) Phone.forDisplay(person.phone),
                ].join(' · ')),
                trailing: Text(
                  _rateLabel(person),
                  style: theme.textTheme.labelMedium,
                ),
                // Tappable, because "what does this teacher take, and what have
                // we paid them" is the question that follows seeing their name.
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => TeacherProfileScreen(staffId: person.id),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  static String _rateLabel(StaffMember p) {
    final parts = <String>[
      if (p.monthlySalary > 0) '৳${p.monthlySalary}/mo',
      if (p.perClassRate > 0) '৳${p.perClassRate}/class',
      if (p.hourlyRate > 0) '৳${p.hourlyRate}/hr',
    ];
    return parts.isEmpty ? '—' : parts.join('\n');
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final result = await showStaffSheet(context: context, isTeacher: teachers);
    if (result == null) return;

    await ref.read(staffRepositoryProvider).add(
          name: result.name,
          isTeacher: teachers,
          phone: result.phone,
          role: result.role,
          payModel: result.payModel,
          monthlySalary: result.monthlySalary,
          perClassRate: result.perClassRate,
          hourlyRate: result.hourlyRate,
        );
  }
}

/// What the add/edit sheet collects.
typedef StaffDetails = ({
  String name,
  String phone,
  String role,
  PayModel payModel,
  int monthlySalary,
  int perClassRate,
  int hourlyRate,
});

/// Collects a person's details.
///
/// All three rates are offered at once rather than behind an either/or choice:
/// a teacher on a per-class rate for routine classes and an hourly rate for
/// extra sittings is normal, and forcing one model would mean the owner keeping
/// the difference in their head.
Future<StaffDetails?> showStaffSheet({
  required BuildContext context,
  required bool isTeacher,
  StaffMember? existing,
}) {
  final name = TextEditingController(text: existing?.name ?? '');
  final phone = TextEditingController(text: existing?.phone ?? '');
  final role = TextEditingController(
      text: existing?.role ?? (isTeacher ? 'Teacher' : 'Staff'));
  final monthly = TextEditingController(text: '${existing?.monthlySalary ?? 0}');
  final perClass = TextEditingController(text: '${existing?.perClassRate ?? 0}');
  final hourly = TextEditingController(text: '${existing?.hourlyRate ?? 0}');
  var payModel = existing?.payModel ?? PayModel.monthly;

  return showModalBottomSheet<StaffDetails>(
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
              Text(
                existing == null
                    ? (isTeacher ? 'Add a teacher' : 'Add staff')
                    : 'Edit ${existing.name}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 14),
              TextField(
                controller: name,
                autofocus: existing == null,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: role,
                decoration: InputDecoration(
                  labelText: 'Role',
                  hintText: isTeacher ? 'Physics teacher' : 'Accounts',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 18),
              Text('How they are paid',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<PayModel>(
                segments: const [
                  ButtonSegment(
                      value: PayModel.monthly, label: Text('Monthly')),
                  ButtonSegment(
                      value: PayModel.perClass, label: Text('Per class')),
                ],
                selected: {
                  payModel == PayModel.hourly ? PayModel.perClass : payModel
                },
                onSelectionChanged: (v) => setSheet(() => payModel = v.first),
              ),
              const SizedBox(height: 12),
              if (payModel == PayModel.monthly)
                TextField(
                  controller: monthly,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Monthly salary',
                    prefixText: '৳ ',
                    border: OutlineInputBorder(),
                  ),
                )
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: perClass,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Per class',
                          prefixText: '৳ ',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: hourly,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Per hour',
                          prefixText: '৳ ',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Routine classes pay the per-class rate. Extra sittings pay '
                  'by the hour. Set both if they do both.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    if (name.text.trim().isEmpty) return;
                    Navigator.pop(context, (
                      name: name.text.trim(),
                      phone: phone.text.trim(),
                      role: role.text.trim(),
                      payModel: payModel,
                      monthlySalary: int.tryParse(monthly.text) ?? 0,
                      perClassRate: int.tryParse(perClass.text) ?? 0,
                      hourlyRate: int.tryParse(hourly.text) ?? 0,
                    ));
                  },
                  child: Text(existing == null ? 'Add' : 'Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
