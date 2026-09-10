import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';

/// Classes, rooms and periods — the three things the routine builder needs
/// before it can do anything.
class MasterDataScreen extends ConsumerWidget {
  const MasterDataScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: const SectionAppBar(
          section: Section.setup,
          title: 'Classes, rooms and times',
          bottom: TabBar(
            tabs: [
              Tab(text: 'Classes'),
              Tab(text: 'Rooms'),
              Tab(text: 'Periods'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_ClassesTab(), _RoomsTab(), _SlotsTab()],
        ),
      ),
    );
  }
}

class _ClassesTab extends ConsumerWidget {
  const _ClassesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(masterDataProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.small(
        onPressed: () => _addClass(context, ref),
        child: const Icon(Icons.add),
      ),
      body: StreamBuilder<List<SchoolClass>>(
        stream: repo.watchClasses(),
        builder: (context, snapshot) {
          final classes = snapshot.data;
          if (classes == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (classes.isEmpty) {
            return const _EmptyHint(
              icon: Icons.class_outlined,
              title: 'No classes yet',
              body: 'Add the classes your centre teaches. Each one holds its '
                  'own subjects.',
            );
          }
          return ListView(
            children: [
              for (final c in classes)
                ExpansionTile(
                  title: Text(c.name),
                  children: [
                    StreamBuilder<List<Subject>>(
                      stream: repo.watchSubjects(c.id),
                      builder: (context, subjectSnap) {
                        final subjects = subjectSnap.data ?? const <Subject>[];
                        if (subjects.isEmpty) {
                          return const ListTile(
                            dense: true,
                            title: Text('No subjects'),
                          );
                        }
                        return Column(
                          children: [
                            for (final s in subjects)
                              ListTile(
                                dense: true,
                                title: Text(s.name),
                                subtitle: Text(
                                  '${s.weeklyClasses} class(es) a week',
                                ),
                                trailing: s.shortName.isEmpty
                                    ? null
                                    : Chip(label: Text(s.shortName)),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addClass(BuildContext context, WidgetRef ref) async {
    final name = await _promptText(
      context,
      title: 'Add class',
      label: 'Class name',
      hint: 'Class 9 — Science',
    );
    if (name != null && name.isNotEmpty) {
      await ref.read(masterDataProvider).addClass(name);
    }
  }
}

class _RoomsTab extends ConsumerWidget {
  const _RoomsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(masterDataProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.small(
        onPressed: () => _addRoom(context, ref),
        child: const Icon(Icons.add),
      ),
      body: StreamBuilder<List<Room>>(
        stream: repo.watchRooms(),
        builder: (context, snapshot) {
          final rooms = snapshot.data;
          if (rooms == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (rooms.isEmpty) {
            return const _EmptyHint(
              icon: Icons.meeting_room_outlined,
              title: 'No rooms yet',
              body: 'The routine builder uses rooms to stop two batches being '
                  'scheduled into the same place, and to catch a batch that '
                  'will not fit.',
            );
          }
          return ListView(
            children: [
              for (final r in rooms)
                ListTile(
                  leading: const Icon(Icons.meeting_room_outlined),
                  title: Text(r.name),
                  subtitle: Text('Seats ${r.capacity}'),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addRoom(BuildContext context, WidgetRef ref) async {
    final name = await _promptText(
      context,
      title: 'Add room',
      label: 'Room name',
      hint: 'Room 3',
    );
    if (name == null || name.isEmpty) return;
    if (!context.mounted) return;
    final capacity = await _promptText(
      context,
      title: 'Capacity of $name',
      label: 'How many students fit?',
      hint: '30',
      number: true,
    );
    await ref
        .read(masterDataProvider)
        .addRoom(name, int.tryParse(capacity ?? '') ?? 30);
  }
}

class _SlotsTab extends ConsumerWidget {
  const _SlotsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(masterDataProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.small(
        onPressed: () => _addSlot(context, ref),
        child: const Icon(Icons.add),
      ),
      body: StreamBuilder<List<TimeSlot>>(
        stream: repo.watchTimeSlots(),
        builder: (context, snapshot) {
          final slots = snapshot.data;
          if (slots == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (slots.isEmpty) {
            return const _EmptyHint(
              icon: Icons.schedule_outlined,
              title: 'No class times yet',
              body: 'Periods are your centre’s own hours — not a fixed grid. '
                  'The routine is built out of these.',
            );
          }
          return ListView(
            children: [
              for (final s in slots)
                ListTile(
                  leading: const Icon(Icons.schedule_outlined),
                  title: Text(s.label.isEmpty
                      ? '${_hhmm(s.startMinute)} – ${_hhmm(s.endMinute)}'
                      : s.label),
                  subtitle: Text('${s.endMinute - s.startMinute} minutes'),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addSlot(BuildContext context, WidgetRef ref) async {
    final start = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 16, minute: 0),
      helpText: 'Period starts',
    );
    if (start == null || !context.mounted) return;
    final end = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: start.hour + 1, minute: start.minute),
      helpText: 'Period ends',
    );
    if (end == null) return;

    final startMinute = start.hour * 60 + start.minute;
    final endMinute = end.hour * 60 + end.minute;
    if (endMinute <= startMinute) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('A period has to end after it starts.'),
          ),
        );
      }
      return;
    }
    await ref.read(masterDataProvider).addTimeSlot(
          label: '${_hhmm(startMinute)} – ${_hhmm(endMinute)}',
          startMinute: startMinute,
          endMinute: endMinute,
        );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44),
              const SizedBox(height: 14),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(body, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}

String _hhmm(int minutes) {
  final h24 = minutes ~/ 60;
  final m = minutes % 60;
  final period = h24 >= 12 ? 'PM' : 'AM';
  final h = h24 % 12 == 0 ? 12 : h24 % 12;
  return '$h:${m.toString().padLeft(2, '0')} $period';
}

Future<String?> _promptText(
  BuildContext context, {
  required String title,
  required String label,
  String? hint,
  bool number = false,
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: number ? TextInputType.number : null,
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Add'),
        ),
      ],
    ),
  );
}
