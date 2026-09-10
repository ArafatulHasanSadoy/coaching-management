import 'package:drift/drift.dart'
    show BooleanExpressionOperators, ComparableExpr, OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';
import '../../data/staff/staff_repository.dart';

/// Who turned up, and how much they taught.
///
/// Two different questions, so two tabs. Marking the day is a daily chore that
/// wants to be fast; the counts are a monthly question the owner asks when
/// working out pay, and they need classes *and* hours side by side because a
/// teacher on both rates earns from both.
class StaffAttendanceScreen extends ConsumerWidget {
  const StaffAttendanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const section = Section.attendance;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: const SectionAppBar(
          section: section,
          title: 'Staff attendance',
          bottom: TabBar(
            tabs: [Tab(text: 'Today'), Tab(text: 'This month')],
          ),
        ),
        body: const TabBarView(
          children: [_MarkToday(), _MonthlyCounts()],
        ),
      ),
    );
  }
}

class _MarkToday extends ConsumerStatefulWidget {
  const _MarkToday();

  @override
  ConsumerState<_MarkToday> createState() => _MarkTodayState();
}

class _MarkTodayState extends ConsumerState<_MarkToday> {
  final _states = <String, AttendanceState>{};
  bool _loaded = false;

  Future<void> _load(List<StaffMember> people) async {
    final db = ref.read(databaseProvider);
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day);

    final existing = await (db.select(db.staffAttendance)
          ..where((t) =>
              t.onDate.isBiggerOrEqualValue(from) &
              t.onDate.isSmallerThanValue(from.add(const Duration(days: 1))) &
              t.deletedAt.isNull()))
        .get();

    if (!mounted) return;
    setState(() {
      _states
        ..clear()
        ..addEntries(people.map((p) => MapEntry(
              p.id,
              existing
                      .where((e) => e.staffId == p.id)
                      .map((e) => e.state)
                      .firstOrNull ??
                  AttendanceState.present,
            )));
      _loaded = true;
    });
  }

  Future<void> _save() async {
    final db = ref.read(databaseProvider);
    final deviceId = ref.read(deviceIdProvider);
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day);

    await db.transaction(() async {
      await (db.delete(db.staffAttendance)
            ..where((t) =>
                t.onDate.isBiggerOrEqualValue(from) &
                t.onDate.isSmallerThanValue(from.add(const Duration(days: 1)))))
          .go();
      await db.batch((b) {
        b.insertAll(db.staffAttendance, [
          for (final entry in _states.entries)
            StaffAttendanceCompanion.insert(
              staffId: entry.key,
              onDate: from,
              state: entry.value,
              deviceId: deviceId,
            ),
        ]);
      });
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Saved')));
  }

  @override
  Widget build(BuildContext context) {
    const section = Section.attendance;
    final db = ref.watch(databaseProvider);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: section.band(context),
        foregroundColor: section.onTint(context),
        onPressed: _loaded ? _save : null,
        icon: const Icon(Icons.check),
        label: const Text('Save'),
      ),
      body: StreamBuilder<List<StaffMember>>(
        stream: (db.select(db.staff)
              ..where((t) => t.deletedAt.isNull() & t.isActive.equals(true))
              ..orderBy([(t) => OrderingTerm.asc(t.name)]))
            .watch(),
        builder: (context, snapshot) {
          final people = snapshot.data;
          if (people == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (people.isEmpty) {
            return const EmptyState(
              section: section,
              title: 'Nobody on the books',
              body: 'Add teachers and staff first.',
            );
          }
          if (!_loaded) {
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _load(people));
            return const Center(child: CircularProgressIndicator());
          }

          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: people.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final person = people[i];
              final state = _states[person.id] ?? AttendanceState.present;
              final (label, colour) = switch (state) {
                AttendanceState.present => ('In', Colors.green),
                AttendanceState.absent => ('Absent', Colors.red),
                AttendanceState.late => ('Late', Colors.orange),
                AttendanceState.excused => ('Leave', Colors.blueGrey),
              };

              return ListTile(
                title: Text(person.name),
                subtitle: Text(person.role),
                trailing: SizedBox(
                  width: 104,
                  child: OutlinedButton(
                    onPressed: () {
                      const order = AttendanceState.values;
                      setState(() => _states[person.id] =
                          order[(order.indexOf(state) + 1) % order.length]);
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colour,
                      side: BorderSide(color: colour),
                    ),
                    child: Text(label),
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

class _MonthlyCounts extends ConsumerStatefulWidget {
  const _MonthlyCounts();

  @override
  ConsumerState<_MonthlyCounts> createState() => _MonthlyCountsState();
}

class _MonthlyCountsState extends ConsumerState<_MonthlyCounts> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  Widget build(BuildContext context) {
    const section = Section.attendance;
    final theme = Theme.of(context);

    return Column(
      children: [
        Container(
          color: section.tint(context),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(
                    () => _month = DateTime(_month.year, _month.month - 1)),
              ),
              Text('${_month.month}/${_month.year}',
                  style: theme.textTheme.titleMedium),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(
                    () => _month = DateTime(_month.year, _month.month + 1)),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<TeacherAttendance>>(
            key: ValueKey(_month),
            future: ref.read(staffRepositoryProvider).attendanceFor(_month),
            builder: (context, snapshot) {
              final rows = snapshot.data;
              if (rows == null) {
                return const Center(child: CircularProgressIndicator());
              }
              if (rows.isEmpty) {
                return const EmptyState(
                  section: section,
                  title: 'No teachers yet',
                  body: 'Counts appear once teachers are added and classes '
                      'are taken.',
                );
              }

              return ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Classes are routine classes. Hours are extra sittings, '
                      'which is what the hourly rate pays for.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  for (final row in rows)
                    ListTile(
                      title: Text(row.staff.name),
                      subtitle: Text(
                        'Present ${row.daysPresent} · absent ${row.daysAbsent}',
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('${row.regularClasses} class(es)',
                              style: theme.textTheme.labelLarge),
                          Text(row.extraHoursLabel,
                              style: theme.textTheme.labelSmall),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
