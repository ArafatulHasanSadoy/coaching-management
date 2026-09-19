import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../app/lock_controller.dart';
import '../../core/phone.dart';
import '../../core/money_guard.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';
import '../../data/documents/document_engine.dart';
import '../../data/documents/receipt_document.dart';
import '../../data/finance/fee_service.dart';

/// Taking money at the counter.
///
/// Built for the shape of the moment it happens in: a guardian is standing
/// there, often on the phone, and the person at the desk needs the whole thing
/// done in seconds. So the search is phone-first, the outstanding amount is
/// shown without asking, and the amount field arrives pre-filled with what is
/// owed.
class CollectFeeScreen extends ConsumerStatefulWidget {
  const CollectFeeScreen({this.student, super.key});

  /// When opened from a student's profile, the search step is skipped.
  final Student? student;

  @override
  ConsumerState<CollectFeeScreen> createState() => _CollectFeeScreenState();
}

class _CollectFeeScreenState extends ConsumerState<CollectFeeScreen> {
  final _query = TextEditingController();
  final _amount = TextEditingController();
  final _reference = TextEditingController();

  List<Student>? _results;
  Student? _selected;
  DueSummary? _dues;
  PaymentMethod _method = PaymentMethod.cash;
  String? _accountId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.student != null) _choose(widget.student!);
  }

  @override
  void dispose() {
    _query.dispose();
    _amount.dispose();
    _reference.dispose();
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

  Future<void> _choose(Student student) async {
    final dues = await ref.read(feeServiceProvider).duesFor(student);
    if (!mounted) return;
    setState(() {
      _selected = student;
      _dues = dues;
      _results = null;
      // Pre-filled with what is owed: the overwhelmingly common case is a
      // guardian clearing the balance, and making them state it is friction.
      // What the guardian actually has to hand over: any advance on file is
      // spent first, so it comes off the suggested amount.
      final toPay = dues.totalDue - dues.creditBalance;
      _amount.text = toPay > 0 ? '$toPay' : '';
    });
  }

  Future<void> _collect() async {
    final amount = int.tryParse(_amount.text.trim()) ?? 0;
    if (amount <= 0 || _selected == null || _accountId == null) return;

    setState(() => _busy = true);
    try {
      final oldest = _dues?.unpaidInvoices.firstOrNull;
      final previousDue = _dues?.totalDue ?? 0;
      final user = ref.read(currentUserProvider);

      final result = await runMoneyWrite(
        context,
        what: 'this payment',
        () => ref.read(feeServiceProvider).collect(
            studentId: _selected!.id,
            invoiceId: oldest?.id,
            amount: amount,
            method: _method,
            accountId: _accountId!,
            reference: _reference.text.trim(),
            receivedBy: user?.name ?? '',
            // What the money actually cleared, not a guess made before it was
            // applied — this is the line a guardian argues about.
            forPeriod: '',
          ),
      );

      if (result == null || !mounted) return;
      await _offerReceipt(result, previousDue);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _offerReceipt(CollectionResult result, int previousDue) async {
    final payment = result.payment;
    final covered = result.settled.map(ReceiptDocument.monthLabel).join(', ');

    final print = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Received ৳${payment.amount}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Receipt ${payment.receiptNo}'),
            if (covered.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Cleared $covered'),
            ],
            if (result.credited > 0) ...[
              const SizedBox(height: 8),
              Text('৳${result.credited} kept as advance'),
            ],
            const SizedBox(height: 8),
            Text(
              result.remainingDue > 0
                  ? 'Still due ৳${result.remainingDue}'
                  : 'Nothing left owing',
              style: TextStyle(
                color: result.remainingDue > 0
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.print),
            label: const Text('Print receipt'),
          ),
        ],
      ),
    );
    if (print != true || !mounted) return;

    final engine = ref.read(documentEngineProvider);
    final placement =
        await ref.read(studentsProvider).placementOf(_selected!.id);
    final html = ReceiptDocument(engine: engine).build(
      payment: payment,
      student: _selected!,
      previousDue: previousDue,
      batchName: placement.batch,
      className: placement.schoolClass,
      settledPeriods: result.settled,
      remainingDue: result.remainingDue,
      credited: result.credited,
      creditUsed: result.creditUsed,
    );
    await engine.printDocument(
      html,
      jobName: 'Receipt ${payment.receiptNo}',
      paper: PaperSize.a5,
    );
  }


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _selected;

    return Scaffold(
      appBar: const SectionAppBar(section: Section.money, title: 'Collect fee'),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (selected == null) ...[
            TextField(
              controller: _query,
              autofocus: true,
              onChanged: _search,
              decoration: const InputDecoration(
                hintText: 'Phone number, name or ID',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            for (final s in _results ?? const <Student>[])
              ListTile(
                leading: CircleAvatar(child: Text(s.name.characters.first)),
                title: Text(s.name),
                subtitle: Text('${s.code} · ${Phone.forDisplay(s.guardianPhone)}'),
                onTap: () => _choose(s),
              ),
            if (_results != null && _results!.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Nobody matches that.', textAlign: TextAlign.center),
              ),
          ] else ...[
            Card(
              color: theme.colorScheme.primaryContainer,
              child: ListTile(
                title: Text(selected.name),
                subtitle: Text(selected.code),
                trailing: widget.student != null
                    ? null
                    : TextButton(
                        onPressed: () => setState(() {
                          _selected = null;
                          _dues = null;
                        }),
                        child: const Text('Change'),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            if (_dues != null)
              Card(
                color: _dues!.totalDue > 0
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _dues!.totalDue > 0
                            ? 'Outstanding ৳${_dues!.totalDue}'
                            : 'Nothing outstanding',
                        style: theme.textTheme.titleMedium,
                      ),
                      if (_dues!.monthsBehind > 0)
                        Text('${_dues!.monthsBehind} unpaid month(s)'),
                      for (final invoice in _dues!.unpaidInvoices.take(4))
                        Text(
                          // A guardian reads "July 2026", not "2026-07".
                          '${ReceiptDocument.monthLabel(invoice.periodKey)} — '
                          '৳${invoice.netAmount - invoice.paidAmount}',
                          style: theme.textTheme.bodySmall,
                        ),
                      if (_dues!.creditBalance > 0) ...[
                        const SizedBox(height: 6),
                        Text(
                          '৳${_dues!.creditBalance} paid in advance — it comes '
                          'off the next month automatically',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _amount,
              keyboardType: TextInputType.number,
              style: theme.textTheme.headlineSmall,
              decoration: const InputDecoration(
                labelText: 'Amount',
                prefixText: '৳ ',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<PaymentMethod>(
              segments: const [
                ButtonSegment(value: PaymentMethod.cash, label: Text('Cash')),
                ButtonSegment(value: PaymentMethod.bkash, label: Text('bKash')),
                ButtonSegment(value: PaymentMethod.nagad, label: Text('Nagad')),
                ButtonSegment(value: PaymentMethod.bank, label: Text('Bank')),
              ],
              selected: {_method},
              onSelectionChanged: (v) => setState(() => _method = v.first),
            ),
            const SizedBox(height: 14),
            _AccountPicker(
              method: _method,
              selected: _accountId,
              onChanged: (v) => setState(() => _accountId = v),
            ),
            if (_method != PaymentMethod.cash) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _reference,
                decoration: const InputDecoration(
                  labelText: 'Transaction reference',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 22),
            FilledButton(
              onPressed: _busy || _accountId == null ? null : _collect,
              child: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Collect'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Picks the wallet the money lands in, defaulting to the one matching the
/// method so the common case needs no thought.
class _AccountPicker extends ConsumerStatefulWidget {
  const _AccountPicker({
    required this.method,
    required this.selected,
    required this.onChanged,
  });

  final PaymentMethod method;
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  ConsumerState<_AccountPicker> createState() => _AccountPickerState();
}

class _AccountPickerState extends ConsumerState<_AccountPicker> {
  @override
  Widget build(BuildContext context) {
    final db = ref.watch(databaseProvider);
    return FutureBuilder<List<Account>>(
      future: (db.select(db.accounts)..where((t) => t.deletedAt.isNull())).get(),
      builder: (context, snapshot) {
        final accounts = snapshot.data ?? const <Account>[];
        if (accounts.isEmpty) return const SizedBox.shrink();

        final wanted = switch (widget.method) {
          PaymentMethod.cash => AccountKind.cash,
          PaymentMethod.bkash => AccountKind.bkash,
          PaymentMethod.nagad => AccountKind.nagad,
          PaymentMethod.bank => AccountKind.bank,
          PaymentMethod.other => AccountKind.other,
        };
        final match = accounts.where((a) => a.kind == wanted).firstOrNull ??
            accounts.first;

        if (widget.selected == null ||
            !accounts.any((a) => a.id == widget.selected)) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => widget.onChanged(match.id),
          );
        }

        return DropdownButtonFormField<String>(
          initialValue:
              accounts.any((a) => a.id == widget.selected) ? widget.selected : null,
          items: [
            for (final a in accounts)
              DropdownMenuItem(value: a.id, child: Text(a.name)),
          ],
          onChanged: widget.onChanged,
          decoration: const InputDecoration(
            labelText: 'Into',
            border: OutlineInputBorder(),
          ),
        );
      },
    );
  }
}
