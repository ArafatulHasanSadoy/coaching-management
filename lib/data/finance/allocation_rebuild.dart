import 'package:drift/drift.dart';

/// Replays every live payment through the oldest-first waterfall.
///
/// Used once, by the v9 upgrade. Before v9 a payment was pinned to a single
/// invoice: three months paid at once showed as one overpaid month and two
/// unpaid ones, and two part-payments could add up to more than the invoice.
/// Copying those links across would carry the mistake into the new model, so
/// instead the history is re-applied the way v9 applies a payment today —
/// in the order the money arrived, oldest month first, with anything left
/// over held as credit.
///
/// Written against raw SQL and explicit column names rather than the generated
/// table classes, because a migration has to keep working after those classes
/// grow new columns. Assumes `payment_allocations` and `student_credits` are
/// empty, which they are at the point the upgrade calls this.
Future<void> rebuildAllocations(GeneratedDatabase db) async {
  final payments = await db.customSelect(
    'SELECT id, student_id, amount FROM payments '
    'WHERE is_cancelled = 0 AND deleted_at IS NULL '
    'ORDER BY received_on, created_at, id',
  ).get();

  final invoices = await db.customSelect(
    "SELECT id, student_id, net_amount FROM invoices "
    "WHERE deleted_at IS NULL AND status != 'waived' "
    'ORDER BY period_key, id',
  ).get();

  // What each invoice can still absorb, grouped by student in period order.
  final open = <String, List<String>>{};
  final netOf = <String, int>{};
  final remaining = <String, int>{};
  for (final row in invoices) {
    final id = row.read<String>('id');
    final net = row.read<int>('net_amount');
    open.putIfAbsent(row.read<String>('student_id'), () => []).add(id);
    netOf[id] = net;
    remaining[id] = net;
  }

  for (final payment in payments) {
    final paymentId = payment.read<String>('id');
    var left = payment.read<int>('amount');

    for (final invoiceId
        in open[payment.read<String>('student_id')] ?? const <String>[]) {
      if (left <= 0) break;
      final room = remaining[invoiceId]!;
      if (room <= 0) continue;

      final take = left < room ? left : room;
      // INSERT … SELECT so the timestamps and device are copied as stored,
      // whatever format the column holds them in.
      // An invoice raised after the money arrived was paid from advance;
      // one that already existed was paid directly. Compared in SQL so the
      // timestamps are compared in whatever format they are stored.
      await db.customStatement(
        'INSERT INTO payment_allocations '
        '(id, payment_id, invoice_id, amount, from_credit, '
        'created_at, updated_at, device_id) '
        'SELECT ?, p.id, ?, ?, '
        '(SELECT i.created_at FROM invoices i WHERE i.id = ?) > p.created_at, '
        'p.created_at, p.updated_at, p.device_id '
        'FROM payments p WHERE p.id = ?',
        ['mig-$paymentId-$invoiceId', invoiceId, take, invoiceId, paymentId],
      );
      remaining[invoiceId] = room - take;
      left -= take;
    }

    if (left > 0) {
      await db.customStatement(
        'INSERT INTO student_credits '
        '(id, student_id, payment_id, amount, reason, created_at, updated_at, device_id) '
        'SELECT ?, student_id, id, ?, ?, created_at, updated_at, device_id '
        'FROM payments WHERE id = ?',
        [
          'mig-credit-$paymentId',
          left,
          'Paid more than was owed (carried from before the upgrade)',
          paymentId,
        ],
      );
    }
  }

  // Every invoice's figures now come from the allocations, including the ones
  // v8 recorded as overpaid.
  for (final entry in remaining.entries) {
    final net = netOf[entry.key]!;
    final paid = net - entry.value;
    final status = paid <= 0
        ? 'unpaid'
        : paid >= net
            ? 'paid'
            : 'partial';
    await db.customStatement(
      'UPDATE invoices SET paid_amount = ?, status = ? WHERE id = ?',
      [paid, status, entry.key],
    );
  }
}
