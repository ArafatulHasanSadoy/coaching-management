import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/phone.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';

/// People who asked but have not joined.
///
/// A parent who rang in March and was never called back is revenue that walked
/// away, and nobody remembers it without a list.
class EnquiriesScreen extends ConsumerWidget {
  const EnquiriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(enquiryProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: const SectionAppBar(section: Section.students, title: 'Enquiries'),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Section.students.colour,
        foregroundColor: Colors.white,
        onPressed: () => _record(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Enquiry'),
      ),
      body: StreamBuilder<List<Enquiry>>(
        stream: service.watchOpen(),
        builder: (context, snapshot) {
          final rows = snapshot.data;
          if (rows == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (rows.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Nobody waiting. Record the people who ring or walk in — the '
                  'ones nobody calls back are the ones who go elsewhere.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final today = DateTime.now();
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final row = rows[i];
              final due = row.followUpOn != null &&
                  row.followUpOn!.isBefore(today.add(const Duration(days: 1)));

              return ListTile(
                leading: Icon(
                  due ? Icons.notifications_active : Icons.person_outline,
                  color: due ? theme.colorScheme.error : null,
                ),
                title: Text(row.name),
                subtitle: Text([
                  if (row.phone.isNotEmpty) Phone.forDisplay(row.phone),
                  if (row.source.isNotEmpty) row.source,
                  if (row.followUpOn != null)
                    'follow up ${_date(row.followUpOn!)}',
                ].join(' · ')),
                trailing: PopupMenuButton<EnquiryStatus>(
                  onSelected: (status) =>
                      service.setStatus(row, status),
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: EnquiryStatus.followUp,
                      child: Text('Called — follow up'),
                    ),
                    PopupMenuItem(
                      value: EnquiryStatus.admitted,
                      child: Text('Joined'),
                    ),
                    PopupMenuItem(
                      value: EnquiryStatus.lost,
                      child: Text('Went elsewhere'),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _record(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final source = TextEditingController();
    var followUp = DateTime.now().add(const Duration(days: 2));

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
              Text('New enquiry',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 14),
              TextField(
                controller: name,
                autofocus: true,
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
                controller: source,
                decoration: const InputDecoration(
                  labelText: 'How they heard of you',
                  hintText: 'Friend, poster, Facebook',
                  border: OutlineInputBorder(),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Call back on'),
                trailing: Text(_date(followUp)),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: followUp,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) setSheet(() => followUp = picked);
                },
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Record'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (saved != true || name.text.trim().isEmpty) return;
    await ref.read(enquiryProvider).record(
          name: name.text,
          phone: phone.text,
          source: source.text.trim(),
          followUpOn: followUp,
        );
  }

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}';
}
