import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../app/lock_controller.dart';
import '../../core/money_guard.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';

/// Wallets, today's movement, expenses and the end-of-day count.
///
/// Owner-only: this is the screen that says how the business is doing.
class FinanceScreen extends ConsumerStatefulWidget {
  const FinanceScreen({super.key});

  @override
  ConsumerState<FinanceScreen> createState() => _FinanceScreenState();
}

class _FinanceScreenState extends ConsumerState<FinanceScreen> {
  int _reloads = 0;
  void _reload() => setState(() => _reloads++);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = ref.watch(ledgerServiceProvider);
    final fees = ref.watch(feeServiceProvider);
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day);
    final monthStart = DateTime(now.year, now.month);

    return Scaffold(
      appBar: const SectionAppBar(section: Section.money, title: 'Finance'),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Section.money.colour,
        foregroundColor: Colors.white,
        onPressed: () => _addExpense(context),
        icon: const Icon(Icons.remove_circle_outline),
        label: const Text('Expense'),
      ),
      body: ListView(
        key: ValueKey(_reloads),
        padding: const EdgeInsets.all(16),
        children: [
          FutureBuilder(
            future: Future.wait([
              ledger.totalsBetween(dayStart, dayStart.add(const Duration(days: 1))),
              ledger.totalsBetween(monthStart, DateTime(now.year, now.month + 1)),
              fees.outstandingTotal(),
            ]),
            builder: (context, snapshot) {
              final data = snapshot.data;
              if (data == null) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final today = data[0] as ({int income, int expense});
              final month = data[1] as ({int income, int expense});
              final outstanding = data[2] as int;

              return Column(
                children: [
                  _Panel(
                    title: 'Today',
                    rows: [
                      ('Collected', today.income, false),
                      ('Spent', today.expense, true),
                      ('Net', today.income - today.expense, false),
                    ],
                  ),
                  _Panel(
                    title: 'This month',
                    rows: [
                      ('Income', month.income, false),
                      ('Expenses', month.expense, true),
                      ('Net', month.income - month.expense, false),
                    ],
                  ),
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: ListTile(
                      title: const Text('Outstanding fees'),
                      trailing: Text(
                        '৳$outstanding',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Text('Accounts', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          FutureBuilder<Map<String, int>>(
            future: ledger.allBalances(),
            builder: (context, snapshot) {
              final balances = snapshot.data;
              if (balances == null) return const SizedBox.shrink();
              return FutureBuilder<List<Account>>(
                future: _accounts(),
                builder: (context, accountSnap) {
                  final accounts = accountSnap.data ?? const <Account>[];
                  return Card(
                    child: Column(
                      children: [
                        for (final a in accounts)
                          ListTile(
                            dense: true,
                            title: Text(a.name),
                            trailing: Text('৳${balances[a.id] ?? 0}'),
                            onTap: () => _closeDay(context, a, balances[a.id] ?? 0),
                          ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 8),
          Text(
            'Tap an account to count it and close the day.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          Text('Expenses this month', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          FutureBuilder<List<(Expense, String)>>(
            future: _monthExpenses(monthStart),
            builder: (context, snapshot) {
              final rows = snapshot.data;
              if (rows == null) return const SizedBox.shrink();
              if (rows.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text('Nothing spent yet this month.',
                      style: theme.textTheme.bodySmall),
                );
              }
              return Card(
                child: Column(
                  children: [
                    for (final (expense, head) in rows)
                      ListTile(
                        dense: true,
                        title: Text(
                          head,
                          style: TextStyle(
                            decoration: expense.isCancelled
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        subtitle: Text([
                          '${expense.spentOn.day}/${expense.spentOn.month}',
                          if (expense.paidTo.isNotEmpty) expense.paidTo,
                          if (expense.isCancelled) 'voided',
                        ].join(' · ')),
                        trailing: Text(
                          '৳${expense.amount}',
                          style: TextStyle(
                            color: expense.isCancelled
                                ? theme.colorScheme.outline
                                : theme.colorScheme.error,
                          ),
                        ),
                        onTap: expense.isCancelled
                            ? null
                            : () => _voidExpense(context, expense, head),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  /// This month's expenses with the name each should be read by.
  Future<List<(Expense, String)>> _monthExpenses(DateTime monthStart) async {
    final db = ref.read(databaseProvider);
    final expenses = await ref.read(expenseServiceProvider).between(
          monthStart,
          DateTime(monthStart.year, monthStart.month + 1),
        );
    final heads = {
      for (final h in await db.select(db.expenseHeads).get()) h.id: h.name,
    };
    return [
      for (final e in expenses)
        (
          e,
          e.customHead.isNotEmpty
              ? e.customHead
              : heads[e.headId] ?? 'Expense',
        ),
    ];
  }

  /// Voids an expense typed by mistake. The row stays, the money comes back.
  Future<void> _voidExpense(
    BuildContext context,
    Expense expense,
    String head,
  ) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Void ৳${expense.amount} — $head?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'It stays in the history, marked voided, and the money goes back '
              'into the account it came out of.',
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
    if (ok != true || !context.mounted) return;

    final done = await runMoneyAction(
      context,
      what: 'voiding this expense',
      () => ref.read(expenseServiceProvider).cancel(
            expense,
            reason: reason.text.trim().isEmpty
                ? 'No reason given'
                : reason.text.trim(),
          ),
    );
    if (done) _reload();
  }

  Future<List<Account>> _accounts() {
    final db = ref.read(databaseProvider);
    return (db.select(db.accounts)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
  }

  Future<void> _addExpense(BuildContext context) async {
    final db = ref.read(databaseProvider);
    final heads = await (db.select(db.expenseHeads)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    final accounts = await _accounts();
    if (!context.mounted || heads.isEmpty || accounts.isEmpty) return;

    final amount = TextEditingController();
    final paidTo = TextEditingController();
    final customHead = TextEditingController();
    var headId = heads.first.id;
    var accountId = accounts.first.id;

    bool isOther(String id) =>
        heads.firstWhere((h) => h.id == id).name.toLowerCase() == 'other';

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
              Text('Record an expense',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: headId,
                items: [
                  for (final h in heads)
                    DropdownMenuItem(value: h.id, child: Text(h.name)),
                ],
                onChanged: (v) => setSheet(() => headId = v!),
                decoration: const InputDecoration(
                  labelText: 'What for',
                  border: OutlineInputBorder(),
                ),
              ),
              // "Other" as the biggest line in a month tells the owner nothing,
              // so it asks what it actually was.
              if (isOther(headId)) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: customHead,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'What was it?',
                    hintText: 'Printer repair',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: amount,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  prefixText: '৳ ',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: paidTo,
                decoration: const InputDecoration(
                  labelText: 'Paid to (optional)',
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
                onChanged: (v) => setSheet(() => accountId = v!),
                decoration: const InputDecoration(
                  labelText: 'From',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 18),
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

    if (saved != true) return;
    final value = int.tryParse(amount.text.trim()) ?? 0;
    if (value <= 0) return;

    if (!context.mounted) return;
    final recorded = await runMoneyWrite(
      context,
      what: 'this expense',
      () => ref.read(expenseServiceProvider).record(
            headId: headId,
            accountId: accountId,
            amount: value,
            paidTo: paidTo.text.trim(),
            customHead: isOther(headId) ? customHead.text.trim() : '',
          ),
    );
    if (recorded == null) return;
    _reload();
  }

  Future<void> _closeDay(
    BuildContext context,
    Account account,
    int expected,
  ) async {
    final counted = TextEditingController(text: '$expected');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Close ${account.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('The app expects ৳$expected.'),
            const SizedBox(height: 12),
            TextField(
              controller: counted,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'What you actually counted',
                prefixText: '৳ ',
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
            child: const Text('Close day'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final user = ref.read(currentUserProvider);
    if (!context.mounted) return;
    final closing = await runMoneyWrite(
      context,
      what: 'a day closing',
      () => ref.read(expenseServiceProvider).closeDay(
            accountId: account.id,
            countedAmount: int.tryParse(counted.text.trim()) ?? expected,
            closedBy: user?.name ?? '',
          ),
    );
    if (closing == null || !context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          closing.difference == 0
              ? 'Counted exactly. Day closed.'
              : closing.difference > 0
                  ? 'Day closed — ৳${closing.difference} more than expected.'
                  : 'Day closed — ৳${-closing.difference} short.',
        ),
      ),
    );
    _reload();
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.rows});

  final String title;
  final List<(String, int, bool)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final (label, value, negative) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(label),
                    Text(
                      '৳$value',
                      style: TextStyle(
                        fontWeight: label == 'Net' ? FontWeight.bold : null,
                        color: negative ? theme.colorScheme.error : null,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
