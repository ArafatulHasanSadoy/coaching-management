import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/money_guard.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';
import '../../data/documents/document_engine.dart';
import '../../data/documents/receipt_document.dart';
import '../finance/collect_fee_screen.dart';

/// The things a student's record can have done to it.
///
/// Gathered in one block rather than scattered through the profile so the
/// destructive ones — dropping a student, moving them — sit together and read
/// as decisions rather than as buttons.
class StudentActions extends ConsumerWidget {
  const StudentActions({
    required this.student,
    required this.onChanged,
    super.key,
  });

  final Student student;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.payments_outlined),
                title: const Text('Collect a fee'),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CollectFeeScreen(student: student),
                    ),
                  );
                  onChanged();
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: const Text('Receipts'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _ReceiptHistory(student: student),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit details'),
                onTap: () => _edit(context, ref),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('Move to another batch'),
                onTap: () => _transfer(context, ref),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.family_restroom),
                title: const Text('Link a sibling'),
                onTap: () => _linkSibling(context, ref),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<Student>>(
          future: ref.read(studentsProvider).siblingsOf(student.id),
          builder: (context, snapshot) {
            final siblings = snapshot.data ?? const <Student>[];
            if (siblings.isEmpty) return const SizedBox.shrink();
            return Card(
              child: Column(
                children: [
                  const ListTile(
                    dense: true,
                    title: Text('Family'),
                  ),
                  for (final sibling in siblings)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.person_outline),
                      title: Text(sibling.name),
                      subtitle: Text(sibling.code),
                    ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: Icon(Icons.person_off_outlined,
                color: Theme.of(context).colorScheme.error),
            title: const Text('Change status'),
            subtitle: Text('Currently ${student.status.name}'),
            onTap: () => _changeStatus(context, ref),
          ),
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController(text: student.name);
    final guardian = TextEditingController(text: student.guardianName);
    final phone = TextEditingController(text: student.guardianPhone);
    final school = TextEditingController(text: student.school);
    final notes = TextEditingController(text: student.notes);
    final fee = TextEditingController(
        text: student.monthlyFee > 0 ? '${student.monthlyFee}' : '');

    final saved = await showModalBottomSheet<bool>(
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
              Text('Edit ${student.code}',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 14),
              for (final (controller, label, keyboard) in [
                (name, 'Student name', null),
                (guardian, 'Guardian name', null),
                (phone, 'Guardian phone', TextInputType.phone),
                (school, 'School / college', null),
              ]) ...[
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
              // Agreed fees change mid-year — a scholarship, a sibling
              // joining — so this has to be editable after admission.
              TextField(
                controller: fee,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Monthly fee',
                  prefixText: '৳ ',
                  helperText: 'Applies from the next month billed. Months '
                      'already billed keep their amount.',
                  helperMaxLines: 2,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notes,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
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

    await ref.read(studentsProvider).update(
          student,
          name: name.text.trim(),
          guardianName: guardian.text.trim(),
          guardianPhone: phone.text.trim(),
          school: school.text.trim(),
          notes: notes.text.trim(),
          monthlyFee: int.tryParse(fee.text.trim()) ?? student.monthlyFee,
        );
    onChanged();
  }

  Future<void> _transfer(BuildContext context, WidgetRef ref) async {
    final session = await ref.read(activeSessionProvider.future);
    if (session == null || !context.mounted) return;
    final batches =
        await ref.read(masterDataProvider).watchBatches(session.id).first;
    if (!context.mounted) return;

    final chosen = await showDialog<StudentBatch>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Move to'),
        children: [
          for (final batch in batches)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, batch),
              child: Text(batch.name),
            ),
        ],
      ),
    );
    if (chosen == null) return;

    await ref.read(studentsProvider).transferBatch(
          student: student,
          toBatchId: chosen.id,
          sessionId: session.id,
        );
    onChanged();
  }

  Future<void> _linkSibling(BuildContext context, WidgetRef ref) async {
    final query = TextEditingController();
    final chosen = await showDialog<Student>(
      context: context,
      builder: (context) => _SiblingPicker(
        exclude: student.id,
        controller: query,
      ),
    );
    if (chosen == null) return;

    await ref.read(studentsProvider).linkSiblings(student.id, chosen.id);
    onChanged();
  }

  Future<void> _changeStatus(BuildContext context, WidgetRef ref) async {
    final chosen = await showDialog<StudentStatus>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Change status'),
        children: [
          for (final status in StudentStatus.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, status),
              child: Text(switch (status) {
                StudentStatus.active => 'Active',
                StudentStatus.inactive => 'On a break',
                StudentStatus.dropped => 'Left the centre',
                StudentStatus.completed => 'Finished',
              }),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == student.status) return;
    if (!context.mounted) return;

    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Mark as ${chosen.name}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (chosen == StudentStatus.dropped ||
                chosen == StudentStatus.completed)
              const Text(
                'They come off batch rosters and attendance. Their record, '
                'fees and history stay exactly as they are.',
              ),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                border: OutlineInputBorder(),
              ),
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
            child: const Text('Change'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await ref
        .read(studentsProvider)
        .setStatus(student, chosen, reason: reason.text.trim());
    onChanged();
  }
}

class _SiblingPicker extends ConsumerStatefulWidget {
  const _SiblingPicker({required this.exclude, required this.controller});
  final String exclude;
  final TextEditingController controller;

  @override
  ConsumerState<_SiblingPicker> createState() => _SiblingPickerState();
}

class _SiblingPickerState extends ConsumerState<_SiblingPicker> {
  List<Student> _results = const [];

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Link a sibling'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: widget.controller,
                autofocus: true,
                onChanged: (value) async {
                  final found =
                      await ref.read(studentsProvider).search(value);
                  if (mounted) {
                    setState(() => _results =
                        found.where((s) => s.id != widget.exclude).toList());
                  }
                },
                decoration: const InputDecoration(
                  hintText: 'Name or phone',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in _results)
                      ListTile(
                        dense: true,
                        title: Text(s.name),
                        subtitle: Text(s.code),
                        onTap: () => Navigator.pop(context, s),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

class _ReceiptHistory extends ConsumerStatefulWidget {
  const _ReceiptHistory({required this.student});
  final Student student;

  @override
  ConsumerState<_ReceiptHistory> createState() => _ReceiptHistoryState();
}

class _ReceiptHistoryState extends ConsumerState<_ReceiptHistory> {
  int _reloads = 0;

  Student get student => widget.student;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: SectionAppBar(
        section: Section.money,
        title: 'Receipts — ${student.name}',
      ),
      body: FutureBuilder<List<Payment>>(
        key: ValueKey(_reloads),
        future: ref.read(feeServiceProvider).paymentsFor(student.id),
        builder: (context, snapshot) {
          final payments = snapshot.data;
          if (payments == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (payments.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('No payments recorded yet.'),
              ),
            );
          }
          return ListView.separated(
            itemCount: payments.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final payment = payments[i];
              return ListTile(
                title: Text(payment.receiptNo,
                    style: TextStyle(
                      decoration: payment.isCancelled
                          ? TextDecoration.lineThrough
                          : null,
                    )),
                subtitle: Text([
                  '${payment.receivedOn.day}/${payment.receivedOn.month}/'
                      '${payment.receivedOn.year}',
                  payment.method.name,
                  if (payment.isCancelled) 'cancelled: ${payment.cancelReason}',
                ].join(' · ')),
                trailing: Text(
                  '৳${payment.amount}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: payment.isCancelled ? theme.colorScheme.error : null,
                  ),
                ),
                onTap: () => _open(payment),
              );
            },
          );
        },
      ),
    );
  }

  /// What can be done with a receipt that has already been written.
  ///
  /// Reprinting and voiding both existed in the services and neither could be
  /// reached: the guardian who loses a receipt and the payment typed against
  /// the wrong student are both ordinary days at the counter.
  Future<void> _open(Payment payment) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('Receipt ${payment.receiptNo}',
                  style: Theme.of(context).textTheme.titleMedium),
              subtitle: Text('৳${payment.amount} · ${student.name}'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.print_outlined),
              title: const Text('Print a copy'),
              subtitle: const Text('Stamped DUPLICATE'),
              onTap: () => Navigator.pop(context, 'print'),
            ),
            if (!payment.isCancelled)
              ListTile(
                leading: const Icon(Icons.undo),
                title: const Text('Void this receipt'),
                subtitle: const Text(
                    'The number stays used and the money is reversed'),
                onTap: () => Navigator.pop(context, 'void'),
              ),
          ],
        ),
      ),
    );

    if (choice == 'print') await _reprint(payment);
    if (choice == 'void') await _void(payment);
  }

  Future<void> _reprint(Payment payment) async {
    final engine = ref.read(documentEngineProvider);
    // A duplicate says what the original said: the months paid on the day
    // and the advance held — not where that advance went afterwards.
    final fees = ref.read(feeServiceProvider);
    final settled = await fees.periodsSettledBy(payment.id);
    final advance = await fees.advanceCreatedBy(payment.id);
    final placement = await ref.read(studentsProvider).placementOf(student.id);

    final html = ReceiptDocument(engine: engine).build(
      payment: payment,
      student: student,
      settledPeriods: settled,
      credited: advance,
      batchName: placement.batch,
      className: placement.schoolClass,
      isDuplicate: true,
    );
    await engine.printDocument(
      html,
      jobName: 'Receipt ${payment.receiptNo} (copy)',
      paper: PaperSize.a5,
    );
  }

  Future<void> _void(Payment payment) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Void receipt ${payment.receiptNo}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The receipt keeps its number and stays in the history, marked '
              'cancelled. The money is reversed and anything it paid goes '
              'back to being owed.',
            ),
            const SizedBox(height: 14),
            TextField(
              controller: reason,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Why',
                hintText: 'Entered twice',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Void'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final done = await runMoneyAction(
      context,
      what: 'voiding this receipt',
      () => ref.read(feeServiceProvider).cancelPayment(
            payment,
            reason: reason.text.trim().isEmpty
                ? 'No reason given'
                : reason.text.trim(),
          ),
    );
    if (!done || !mounted) return;
    setState(() => _reloads++);
  }
}
