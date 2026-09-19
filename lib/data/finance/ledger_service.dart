import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';

/// The money ledger.
///
/// Entries are append-only. Nothing is edited, nothing is deleted, and a
/// correction is a new entry pointing back at what it undoes. That makes a
/// balance the plain sum of its rows — provable rather than believed — and it
/// keeps the fact that a correction happened visible instead of erasing it.
class LedgerService {
  const LedgerService({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  /// Writes one entry. Positive is money in, negative is money out.
  Future<LedgerEntry> post({
    required String accountId,
    required int amount,
    required LedgerKind kind,
    required DateTime occurredOn,
    String description = '',
    String sourceEntity = '',
    String sourceId = '',
    String? reversesId,
  }) =>
      db.into(db.ledgerEntries).insertReturning(
            LedgerEntriesCompanion.insert(
              accountId: accountId,
              amount: amount,
              kind: kind,
              occurredOn: occurredOn,
              deviceId: deviceId,
              description: Value(description),
              sourceEntity: Value(sourceEntity),
              sourceId: Value(sourceId),
              reversesId: Value(reversesId),
            ),
          );

  /// Undoes [entry] by writing its opposite.
  Future<LedgerEntry> reverse(LedgerEntry entry, {String reason = ''}) => post(
        accountId: entry.accountId,
        amount: -entry.amount,
        kind: LedgerKind.adjustment,
        occurredOn: DateTime.now(),
        description: reason.isEmpty ? 'Reversal' : 'Reversal — $reason',
        sourceEntity: entry.sourceEntity,
        sourceId: entry.sourceId,
        reversesId: entry.id,
      );

  /// Reverses every live entry produced by one source record.
  Future<void> reverseSource({
    required String sourceEntity,
    required String sourceId,
    String reason = '',
  }) async {
    final entries = await (db.select(db.ledgerEntries)
          ..where((t) =>
              t.sourceEntity.equals(sourceEntity) &
              t.sourceId.equals(sourceId) &
              t.deletedAt.isNull()))
        .get();

    final alreadyReversed = {
      for (final e in entries)
        if (e.reversesId != null) e.reversesId!,
    };

    for (final entry in entries) {
      if (entry.reversesId != null) continue;
      if (alreadyReversed.contains(entry.id)) continue;
      await reverse(entry, reason: reason);
    }
  }

  /// Balance of one account: its opening figure plus every entry against it.
  Future<int> balanceOf(String accountId) async {
    final account = await (db.select(db.accounts)
          ..where((t) => t.id.equals(accountId)))
        .getSingleOrNull();
    if (account == null) return 0;

    final sum = db.ledgerEntries.amount.sum();
    final row = await (db.selectOnly(db.ledgerEntries)
          ..addColumns([sum])
          ..where(db.ledgerEntries.accountId.equals(accountId) &
              db.ledgerEntries.deletedAt.isNull()))
        .getSingle();

    return account.openingBalance + (row.read(sum) ?? 0);
  }

  Future<Map<String, int>> allBalances() async {
    final accounts = await (db.select(db.accounts)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    return {
      for (final a in accounts) a.id: await balanceOf(a.id),
    };
  }

  /// Totals between two dates. Used by the day and month summaries.
  Future<({int income, int expense})> totalsBetween(
    DateTime from,
    DateTime to,
  ) async {
    final rows = await (db.select(db.ledgerEntries)
          ..where((t) =>
              t.occurredOn.isBiggerOrEqualValue(from) &
              t.occurredOn.isSmallerThanValue(to) &
              t.deletedAt.isNull()))
        .get();

    // A reversal undoes the side its original was on. Classifying by sign
    // alone turned a voided fee into an "expense" and a voided expense into
    // "income" — the balance stayed right while both totals went wrong, which
    // is the worst kind of wrong because nothing looks broken. The original
    // may sit outside the range (voiding last month's receipt today), so it
    // is looked up rather than assumed to be in `rows`.
    final reversedIds = {
      for (final r in rows)
        if (r.reversesId != null) r.reversesId!,
    };
    final originals = reversedIds.isEmpty
        ? const <String, LedgerEntry>{}
        : {
            for (final e in await (db.select(db.ledgerEntries)
                  ..where((t) => t.id.isIn(reversedIds)))
                .get())
              e.id: e,
          };

    var income = 0;
    var expense = 0;
    for (final r in rows) {
      // Moving money between the centre's own accounts earns and costs
      // nothing.
      if (r.kind == LedgerKind.transfer) continue;

      final original = r.reversesId == null ? null : originals[r.reversesId];
      final wasIncome = original == null ? r.amount >= 0 : original.amount >= 0;

      if (original != null) {
        // r.amount is the opposite sign of the original, so adding it to
        // the original's side is exactly "take it back off".
        if (wasIncome) {
          income += r.amount;
        } else {
          expense -= r.amount;
        }
      } else if (wasIncome) {
        income += r.amount;
      } else {
        expense += -r.amount;
      }
    }
    return (income: income, expense: expense);
  }
}
