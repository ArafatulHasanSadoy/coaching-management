import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/db/tables.dart';
import '../../data/finance/payroll_service.dart';

/// What each teacher is owed this month.
///
/// Per-class pay is read off the class-taken register rather than typed in,
/// which is the point of recording who taught each session.
class PayrollScreen extends ConsumerStatefulWidget {
  const PayrollScreen({super.key});

  @override
  ConsumerState<PayrollScreen> createState() => _PayrollScreenState();
}

class _PayrollScreenState extends ConsumerState<PayrollScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  int _reloads = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: SectionAppBar(
        section: Section.teachers,
        title: 'Payroll',
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => setState(
                () => _month = DateTime(_month.year, _month.month - 1)),
          ),
          Center(child: Text('${_month.month}/${_month.year}')),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () => setState(
                () => _month = DateTime(_month.year, _month.month + 1)),
          ),
        ],
      ),
      body: FutureBuilder<List<PayslipLine>>(
        key: ValueKey('$_month$_reloads'),
        future: ref.read(payrollProvider).payrollFor(_month),
        builder: (context, snapshot) {
          final lines = snapshot.data;
          if (lines == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (lines.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No staff on the books yet. Add teachers first — per-class pay '
                  'is worked out from the classes they actually took.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final owed = lines.fold<int>(0, (sum, l) => sum + l.outstanding);

          return Column(
            children: [
              Container(
                width: double.infinity,
                color: theme.colorScheme.secondaryContainer,
                padding: const EdgeInsets.all(14),
                child: Text('৳$owed still to pay this month',
                    style: theme.textTheme.titleMedium),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: lines.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final line = lines[i];
                    return ListTile(
                      title: Text(line.staff.name),
                      subtitle: Text(switch (line.staff.payModel) {
                        PayModel.monthly => 'Monthly salary',
                        PayModel.perClass =>
                          '${line.classesTaught} class(es) × ৳${line.staff.perClassRate}',
                        PayModel.hourly =>
                          '${line.classesTaught} session(s) × ৳${line.staff.perClassRate}',
                      }),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('৳${line.gross}',
                              style: theme.textTheme.titleSmall),
                          if (line.alreadyPaid > 0)
                            Text('paid ৳${line.alreadyPaid}',
                                style: theme.textTheme.labelSmall),
                        ],
                      ),
                      onTap: line.outstanding <= 0 ? null : () => _pay(line),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pay(PayslipLine line) async {
    final db = ref.read(databaseProvider);
    final accounts = await (db.select(db.accounts)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    if (accounts.isEmpty || !mounted) return;

    final amount = TextEditingController(text: '${line.outstanding}');
    var accountId = accounts.first.id;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text('Pay ${line.staff.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: amount,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  prefixText: '৳ ',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: accountId,
                items: [
                  for (final a in accounts)
                    DropdownMenuItem(value: a.id, child: Text(a.name)),
                ],
                onChanged: (v) => setDialog(() => accountId = v!),
                decoration: const InputDecoration(
                  labelText: 'From',
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
              child: const Text('Pay'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    await ref.read(expenseServiceProvider).paySalary(
          staffId: line.staff.id,
          accountId: accountId,
          periodKey: line.periodKey,
          grossAmount: int.tryParse(amount.text) ?? line.outstanding,
        );
    setState(() => _reloads++);
  }
}
