import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/phone.dart';
import '../../core/period.dart';
import '../../core/sections.dart';
import '../../data/finance/fee_service.dart';
import 'collect_fee_screen.dart';

/// Who owes what — the list the front desk works through.
class DuesScreen extends ConsumerStatefulWidget {
  const DuesScreen({super.key});

  @override
  ConsumerState<DuesScreen> createState() => _DuesScreenState();
}

class _DuesScreenState extends ConsumerState<DuesScreen> {
  int _minMonths = 1;
  Future<List<DueSummary>>? _future;

  @override
  void initState() {
    super.initState();
    // Assigned directly rather than through _reload: setState during initState
    // is pointless, and the widget has not been built yet.
    _future = _query();
  }

  Future<List<DueSummary>> _query() =>
      ref.read(feeServiceProvider).defaulters(minMonths: _minMonths);

  void _reload() {
    // Block body, not an arrow: `() => _future = ...` returns the assigned
    // Future, and setState rejects a callback that returns one.
    setState(() {
      _future = _query();
    });
  }

  /// Raises monthly tuition for everyone enrolled.
  ///
  /// Manual rather than scheduled: a centre decides when its month starts, and
  /// billing that fires on its own would be the app making a financial decision
  /// nobody asked it to make. Safe to press twice — already-billed students are
  /// skipped.
  Future<void> _generate() async {
    final session = await ref.read(activeSessionProvider.future);
    if (session == null || !mounted) return;

    final now = DateTime.now();
    final label = monthLabel(FeeService.periodKeyFor(now));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Raise fees for $label?'),
        content: const Text(
          'Every enrolled student gets an invoice for their own monthly fee, '
          'minus any discount. Anyone already billed for this month is '
          'skipped, so this is safe to run again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Raise fees'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final result = await ref.read(feeServiceProvider).raiseMonthlyFees(
          sessionId: session.id,
          forMonth: DateTime(now.year, now.month),
        );
    if (!mounted) return;

    _reload();

    // Students with no fee are the case that matters: a new centre that has
    // not set fees yet would otherwise be told billing is done.
    if (result.withoutFee.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(result.created == 0
              ? 'Nobody was billed'
              : '${result.created} billed — ${result.withoutFee.length} skipped'),
          content: Text(
            '${result.withoutFee.length} student(s) have no monthly fee set, '
            'so there was nothing to charge them:\n\n'
            '${result.withoutFee.take(8).join(', ')}'
            '${result.withoutFee.length > 8 ? ' and ${result.withoutFee.length - 8} more' : ''}'
            '\n\nSet a fee on each student (Students → the student → Edit '
            'details) or on their batch, then raise fees again. Anyone already '
            'billed is skipped.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Got it'),
            ),
          ],
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.created > 0
              ? '${result.created} invoice(s) raised for $label.'
              : result.alreadyBilled > 0
                  ? 'Everyone was already billed for $label.'
                  : 'No one is enrolled in a batch yet, so there was no one '
                      'to bill.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: SectionAppBar(
        section: Section.money,
        title: 'Dues',
        actions: [
          IconButton(
            tooltip: 'Raise this month\u2019s fees',
            icon: const Icon(Icons.playlist_add),
            onPressed: _generate,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('1 month+')),
                ButtonSegment(value: 2, label: Text('2 months+')),
                ButtonSegment(value: 3, label: Text('3 months+')),
              ],
              selected: {_minMonths},
              onSelectionChanged: (v) {
                _minMonths = v.first;
                _reload();
              },
            ),
          ),
          Expanded(
            child: FutureBuilder<List<DueSummary>>(
              future: _future,
              builder: (context, snapshot) {
                final list = snapshot.data;
                if (list == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (list.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Nobody is behind by that much. Either collection is '
                        'going well, or invoices have not been generated yet.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                final total = list.fold<int>(0, (s, d) => s + d.totalDue);
                return Column(
                  children: [
                    Container(
                      width: double.infinity,
                      color: theme.colorScheme.errorContainer,
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        '৳$total outstanding across ${list.length} students',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    Expanded(
                      child: ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final due = list[i];
                          return ListTile(
                            title: Text(due.student.name),
                            subtitle: Text([
                              '${due.monthsBehind} month(s)',
                              if (due.student.guardianPhone.isNotEmpty)
                                Phone.forDisplay(due.student.guardianPhone),
                            ].join(' · ')),
                            trailing: Text(
                              '৳${due.totalDue}',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                            onTap: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      CollectFeeScreen(student: due.student),
                                ),
                              );
                              _reload();
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
