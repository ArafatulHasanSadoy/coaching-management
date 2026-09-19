import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../app/lock_controller.dart';
import '../../core/app_settings.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';

/// Everything the wizard set, plus the things it never asked about.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int _reloads = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final institution = ref.watch(institutionProvider).value;

    return Scaffold(
      appBar: const SectionAppBar(section: Section.setup, title: 'Settings'),
      body: ListView(
        key: ValueKey(_reloads),
        children: [
          const _Heading('Centre'),
          ListTile(
            title: const Text('Name and address'),
            subtitle: Text(institution?.name ?? '—'),
            trailing: const Icon(Icons.chevron_right),
            onTap: institution == null ? null : () => _editProfile(institution),
          ),
          ListTile(
            title: const Text('Student ID pattern'),
            subtitle: Text(institution?.studentIdPattern ?? '—'),
            trailing: const Icon(Icons.chevron_right),
            onTap: institution == null ? null : () => _editPattern(institution),
          ),

          const _Heading('Security'),
          FutureBuilder<int>(
            future: ref.read(settingsProvider).readInt(AppSettings.autoLockMinutes),
            builder: (context, snapshot) {
              final minutes = snapshot.data ?? LockController.defaultIdleMinutes;
              return ListTile(
                title: const Text('Lock after'),
                subtitle: Text('$minutes minute(s) of no use'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _editAutoLock(minutes),
              );
            },
          ),

          const _Heading('Fees'),
          FutureBuilder<List<String>>(
            future: Future.wait([
              ref.read(settingsProvider).read(AppSettings.defaultDueDay),
              ref.read(settingsProvider).read(AppSettings.receiptPrefix),
            ]),
            builder: (context, snapshot) {
              final values = snapshot.data;
              if (values == null) return const SizedBox.shrink();
              final dueDay = values[0];
              final prefix = values[1];
              return Column(
                children: [
                  ListTile(
                    title: const Text('Fees are due by'),
                    subtitle: Text('Day $dueDay of each month'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _editDueDay(int.tryParse(dueDay) ?? 10),
                  ),
                  ListTile(
                    title: const Text('Receipt numbers'),
                    subtitle: Text('$prefix-00001, $prefix-00002 …'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _editReceiptPrefix(prefix),
                  ),
                ],
              );
            },
          ),

          const _Heading('Accounting'),
          ListTile(
            title: const Text('Closed months'),
            subtitle: const Text(
              'Once a month is closed, nothing dated inside it can be changed.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _manageLocks,
          ),

          const _Heading('Sessions'),
          ListTile(
            title: const Text('Academic sessions'),
            subtitle: const Text('Switch year, or promote batches into the next'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _manageSessions,
          ),

          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              'Coaching Ops · works entirely offline',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editProfile(Institution institution) async {
    final name = TextEditingController(text: institution.name);
    final address = TextEditingController(text: institution.address);
    final phone = TextEditingController(text: institution.phone);
    final footer = TextEditingController(text: institution.receiptFooter);

    final saved = await _sheet(
      title: 'Centre details',
      fields: [
        (name, 'Centre name', null),
        (address, 'Address', null),
        (phone, 'Phone', TextInputType.phone),
        (footer, 'Receipt footer', null),
      ],
    );
    if (saved != true) return;

    await ref.read(masterDataProvider).updateInstitution(
          institution,
          name: name.text.trim(),
          address: address.text.trim(),
          phone: phone.text.trim(),
          receiptFooter: footer.text.trim(),
        );
    ref.invalidate(institutionProvider);
    setState(() => _reloads++);
  }

  Future<void> _editPattern(Institution institution) async {
    final pattern = TextEditingController(text: institution.studentIdPattern);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Student ID pattern'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '{YY} is the two-digit year, {YYYY} the full year, and each # is '
              'a digit of the running number.\n\nAEC-{YY}-{#####} gives '
              'AEC-26-00427.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pattern,
              autofocus: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            const Text(
              'Existing students keep the IDs they already have.',
              style: TextStyle(fontSize: 12),
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
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;

    await ref
        .read(masterDataProvider)
        .updateInstitution(institution, studentIdPattern: pattern.text.trim());
    ref.invalidate(institutionProvider);
    setState(() => _reloads++);
  }

  Future<void> _editAutoLock(int current) async {
    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Lock after'),
        children: [
          for (final minutes in [1, 3, 5, 10, 30])
            RadioListTile<int>(
              value: minutes,
              // ignore: deprecated_member_use
              groupValue: current,
              // ignore: deprecated_member_use
              onChanged: (v) => Navigator.pop(context, v),
              title: Text('$minutes minute(s)'),
            ),
        ],
      ),
    );
    if (chosen == null) return;

    await ref
        .read(settingsProvider)
        .write(AppSettings.autoLockMinutes, '$chosen');
    ref.read(lockControllerProvider.notifier).setIdleMinutes(chosen);
    setState(() => _reloads++);
  }

  /// Every centre collects by its own day of the month; it drives when an
  /// invoice counts as overdue.
  Future<void> _editDueDay(int current) async {
    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Fees are due by'),
        children: [
          SizedBox(
            width: 280,
            child: GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(12),
              children: [
                // 28 at most, so the day exists in every month.
                for (var day = 1; day <= 28; day++)
                  InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => Navigator.pop(context, day),
                    child: Center(
                      child: CircleAvatar(
                        radius: 16,
                        backgroundColor: day == current
                            ? Section.money.colour
                            : Colors.transparent,
                        foregroundColor:
                            day == current ? Colors.white : null,
                        child: Text('$day'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (chosen == null) return;
    await ref
        .read(settingsProvider)
        .write(AppSettings.defaultDueDay, '$chosen');
    setState(() => _reloads++);
  }

  /// The letters in front of every receipt number. Changing it starts a new
  /// book at 1; the old one keeps its numbers.
  Future<void> _editReceiptPrefix(String current) async {
    final controller = TextEditingController(text: current);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Receipt numbers'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              maxLength: 8,
              decoration: const InputDecoration(
                labelText: 'Starts with',
                hintText: 'R',
                border: OutlineInputBorder(),
              ),
            ),
            const Text(
              'A new prefix starts a new receipt book from 1. Receipts already '
              'written keep their numbers.',
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
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final value = controller.text.trim().toUpperCase();
    if (saved != true || value.isEmpty || value == current) return;
    // Letters, digits and dashes only: it is printed and read aloud.
    if (!RegExp(r'^[A-Z0-9-]+$').hasMatch(value)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Use letters, numbers or a dash only.'),
        ),
      );
      return;
    }
    await ref.read(settingsProvider).write(AppSettings.receiptPrefix, value);
    setState(() => _reloads++);
  }

  Future<void> _manageLocks() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const _ClosedMonthsScreen()),
    );
    setState(() => _reloads++);
  }

  Future<void> _manageSessions() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const _SessionsScreen()),
    );
    ref.invalidate(activeSessionProvider);
    setState(() => _reloads++);
  }

  Future<bool?> _sheet({
    required String title,
    required List<(TextEditingController, String, TextInputType?)> fields,
  }) =>
      showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        builder: (context) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                for (final (controller, label, keyboard) in fields) ...[
                  TextField(
                    controller: controller,
                    keyboardType: keyboard,
                    decoration: InputDecoration(
                      labelText: label,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
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

class _ClosedMonthsScreen extends ConsumerStatefulWidget {
  const _ClosedMonthsScreen();

  @override
  ConsumerState<_ClosedMonthsScreen> createState() =>
      _ClosedMonthsScreenState();
}

class _ClosedMonthsScreenState extends ConsumerState<_ClosedMonthsScreen> {
  int _reloads = 0;

  @override
  Widget build(BuildContext context) {
    final locks = ref.watch(periodLockProvider);

    return Scaffold(
      appBar: const SectionAppBar(section: Section.money, title: 'Closed months'),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Section.money.colour,
        foregroundColor: Colors.white,
        onPressed: _close,
        icon: const Icon(Icons.lock_outline),
        label: const Text('Close a month'),
      ),
      body: FutureBuilder<List<PeriodLock>>(
        key: ValueKey(_reloads),
        future: locks.locked(),
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
                  'No months are closed. Closing one freezes its figures, so a '
                  'number you have already reported cannot quietly change.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            children: [
              for (final row in rows)
                ListTile(
                  leading: const Icon(Icons.lock),
                  title: Text(row.periodKey),
                  subtitle: Text(row.lockedBy.isEmpty
                      ? 'Closed'
                      : 'Closed by ${row.lockedBy}'),
                  trailing: TextButton(
                    onPressed: () => _reopen(row),
                    child: const Text('Reopen'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _close() async {
    final now = DateTime.now();
    final month = DateTime(now.year, now.month - 1);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Close ${month.month}/${month.year}?'),
        content: const Text(
          'Nothing dated in that month can be recorded or cancelled afterwards. '
          'You can reopen it if something turns up.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Close it'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await ref.read(periodLockProvider).lock(
          month,
          by: ref.read(currentUserProvider)?.name ?? '',
        );
    setState(() => _reloads++);
  }

  Future<void> _reopen(PeriodLock row) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Reopen ${row.periodKey}?'),
        content: TextField(
          controller: reason,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Why',
            helperText: 'Recorded in the audit trail.',
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
            child: const Text('Reopen'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await ref
        .read(periodLockProvider)
        .unlock(row, reason: reason.text.trim());
    setState(() => _reloads++);
  }
}

class _SessionsScreen extends ConsumerStatefulWidget {
  const _SessionsScreen();

  @override
  ConsumerState<_SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<_SessionsScreen> {
  int _reloads = 0;

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(sessionServiceProvider);

    return Scaffold(
      appBar: const SectionAppBar(section: Section.setup, title: 'Academic sessions'),
      body: FutureBuilder<List<AcademicSession>>(
        key: ValueKey(_reloads),
        future: service.all(),
        builder: (context, snapshot) {
          final sessions = snapshot.data;
          if (sessions == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            children: [
              for (final session in sessions)
                ListTile(
                  leading: Icon(session.isActive
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked),
                  title: Text(session.name),
                  subtitle: Text(session.isActive ? 'Current' : 'Past'),
                  trailing: session.isActive
                      ? TextButton(
                          onPressed: () => _rollOver(session),
                          child: const Text('Next year'),
                        )
                      : TextButton(
                          onPressed: () async {
                            await service.activate(session);
                            setState(() => _reloads++);
                          },
                          child: const Text('Make current'),
                        ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _rollOver(AcademicSession from) async {
    final service = ref.read(sessionServiceProvider);
    final plan = await service.planRollover(from);
    if (!mounted) return;

    final controllers = {
      for (final batch in plan.batches)
        batch.id: TextEditingController(text: batch.name),
    };
    // Sessions are usually named by year, so guess the next one; the field is
    // free text for centres that name them differently.
    final year = int.tryParse(from.name) ?? DateTime.now().year;
    final name = TextEditingController(text: '${year + 1}');

    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(20),
          children: [
            Text('Start the next year',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              '${plan.studentCount} students in ${plan.batches.length} '
              'batch(es) will be carried forward. '
              '${from.name} is left exactly as it is — its fees, attendance and '
              'receipts stay where they are.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: name,
              decoration: const InputDecoration(
                labelText: 'New session name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Text('What each batch becomes',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Clear a name to leave that batch behind — its students finished.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            for (final batch in plan.batches)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  controller: controllers[batch.id],
                  decoration: InputDecoration(
                    labelText: batch.name,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Create next year'),
            ),
          ],
        ),
      ),
    );
    if (go != true) return;

    final mapping = <String, String>{
      for (final entry in controllers.entries)
        if (entry.value.text.trim().isNotEmpty)
          entry.key: entry.value.text.trim(),
    };

    final startYear = int.tryParse(name.text.trim()) ?? year + 1;
    await service.rollOver(
      from: from,
      newName: name.text.trim(),
      startDate: DateTime(startYear, 1, 1),
      endDate: DateTime(startYear, 12, 31),
      batchMapping: mapping,
    );

    ref.invalidate(activeSessionProvider);
    if (mounted) setState(() => _reloads++);
  }
}
