import 'package:flutter/material.dart';

import '../data/finance/period_lock_service.dart';
import 'period.dart';
import 'sections.dart';

/// Runs a money write and explains a closed month instead of crashing.
///
/// Every write that touches money asks [PeriodLockService.assertOpen] first,
/// and nothing in the interface used to catch what it throws — so taking a fee
/// dated into a month the owner had already closed took the screen down rather
/// than telling them why. The lock is deliberate and worth keeping; it just has
/// to say what happened, why, and what to do about it.
///
/// Returns `null` when the write was refused, so callers can simply stop.
Future<T?> runMoneyWrite<T>(
  BuildContext context,
  Future<T> Function() write, {
  String what = 'this',
}) async {
  try {
    return await write();
  } on PeriodLockedException catch (error) {
    if (!context.mounted) return null;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.lock_outline, color: Section.money.colour),
        title: Text('${monthLabel(error.periodKey)} is closed'),
        content: Text(
          'You closed the books for ${monthLabel(error.periodKey)}, so $what '
          'cannot be dated into it — the totals for that month have already '
          'been reported.\n\n'
          'Either date it in the current month, or reopen '
          '${monthLabel(error.periodKey)} from Settings → Closed months. '
          'Reopening is recorded.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
    return null;
  }
}

/// The same guard for a write that returns nothing.
///
/// `true` when it went through, `false` when the month was closed — so the
/// caller can simply stop without having to reason about `void?`.
Future<bool> runMoneyAction(
  BuildContext context,
  Future<void> Function() write, {
  String what = 'this',
}) async {
  final done = await runMoneyWrite<bool>(
    context,
    () async {
      await write();
      return true;
    },
    what: what,
  );
  return done ?? false;
}
