import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/tables.dart';

/// Books, sheets, A4 paper, toner, ID cards.
///
/// Every movement carries a reason, so the quantity on screen can always be
/// explained. A stock figure nobody can account for is the same problem as a
/// cash figure nobody can account for.
class InventoryService {
  const InventoryService({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  Stream<List<InventoryItem>> watchItems() => (db.select(db.inventoryItems)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .watch();

  /// Items at or below their minimum. Drives the low-stock warning.
  Future<List<InventoryItem>> lowStock() async {
    final items = await (db.select(db.inventoryItems)
          ..where((t) => t.deletedAt.isNull() & t.isActive.equals(true)))
        .get();
    return items
        .where((i) => i.minimumQuantity > 0 &&
            i.currentQuantity <= i.minimumQuantity)
        .toList();
  }

  Future<InventoryItem> addItem({
    required String name,
    String category = '',
    String unit = 'pcs',
    int openingQuantity = 0,
    int minimumQuantity = 0,
    int purchasePrice = 0,
    int sellingPrice = 0,
    String supplier = '',
  }) async {
    return db.transaction(() async {
      final item = await db.into(db.inventoryItems).insertReturning(
            InventoryItemsCompanion.insert(
              name: name,
              deviceId: deviceId,
              category: Value(category),
              unit: Value(unit),
              currentQuantity: Value(openingQuantity),
              minimumQuantity: Value(minimumQuantity),
              purchasePrice: Value(purchasePrice),
              sellingPrice: Value(sellingPrice),
              supplier: Value(supplier),
            ),
          );

      if (openingQuantity != 0) {
        await db.into(db.stockTransactions).insert(
              StockTransactionsCompanion.insert(
                itemId: item.id,
                move: StockMove.correction,
                quantity: openingQuantity,
                occurredOn: DateTime.now(),
                deviceId: deviceId,
                reason: const Value('Opening stock'),
              ),
            );
      }

      await db.recordChange(
        entity: 'inventory_items',
        entityId: item.id,
        op: ChangeOp.insert,
        deviceId: deviceId,
        action: 'item_added',
        after: {'name': name, 'opening': openingQuantity},
      );
      return item;
    });
  }

  /// Moves stock and keeps the running total in step.
  ///
  /// The transaction row and the item's quantity are written together; a
  /// movement recorded without updating the total, or the reverse, is how a
  /// stock list stops matching the shelf.
  Future<void> move({
    required InventoryItem item,
    required StockMove move,
    required int quantity,
    String reason = '',
    String reference = '',
    DateTime? on,
  }) async {
    if (quantity == 0) return;

    // Receiving adds, everything else removes, regardless of the sign given.
    final signed = switch (move) {
      StockMove.receive => quantity.abs(),
      StockMove.issue || StockMove.damage => -quantity.abs(),
      StockMove.correction => quantity,
    };

    await db.transaction(() async {
      await db.into(db.stockTransactions).insert(
            StockTransactionsCompanion.insert(
              itemId: item.id,
              move: move,
              quantity: signed,
              occurredOn: on ?? DateTime.now(),
              deviceId: deviceId,
              reason: Value(reason),
              reference: Value(reference),
            ),
          );

      await (db.update(db.inventoryItems)..where((t) => t.id.equals(item.id)))
          .write(
        InventoryItemsCompanion(
          currentQuantity: Value(item.currentQuantity + signed),
          updatedAt: Value(DateTime.now()),
        ),
      );

      await db.recordChange(
        entity: 'inventory_items',
        entityId: item.id,
        op: ChangeOp.update,
        deviceId: deviceId,
        action: 'stock_${move.name}',
        before: {'quantity': item.currentQuantity},
        after: {'quantity': item.currentQuantity + signed, 'reason': reason},
      );
    });
  }

  /// Recomputes an item's quantity from its movements.
  ///
  /// The running total is a cache; this is the source of truth. Used by tests
  /// and available if a figure is ever doubted.
  Future<int> quantityFromHistory(String itemId) async {
    final rows = await (db.select(db.stockTransactions)
          ..where((t) => t.itemId.equals(itemId) & t.deletedAt.isNull()))
        .get();
    return rows.fold<int>(0, (sum, t) => sum + t.quantity);
  }

  Future<List<StockTransaction>> historyFor(String itemId) =>
      (db.select(db.stockTransactions)
            ..where((t) => t.itemId.equals(itemId) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.occurredOn)]))
          .get();
}
