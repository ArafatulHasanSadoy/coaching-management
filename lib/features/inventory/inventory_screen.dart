import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/bootstrap.dart';
import '../../core/sections.dart';
import '../../data/db/database.dart';
import '../../data/db/tables.dart';

/// Books, sheets, paper, toner.
class InventoryScreen extends ConsumerWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(inventoryServiceProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: const SectionAppBar(section: Section.stock, title: 'Inventory'),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Section.stock.colour,
        foregroundColor: Colors.white,
        onPressed: () => _addItem(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Item'),
      ),
      body: StreamBuilder<List<InventoryItem>>(
        stream: service.watchItems(),
        builder: (context, snapshot) {
          final items = snapshot.data;
          if (items == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Nothing tracked yet. Add what you buy and hand out — books, '
                  'sheets, A4 paper, toner — and the app will warn you before '
                  'you run out.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final low = items
              .where((i) =>
                  i.minimumQuantity > 0 &&
                  i.currentQuantity <= i.minimumQuantity)
              .toList();

          return ListView(
            children: [
              if (low.isNotEmpty)
                Container(
                  width: double.infinity,
                  color: theme.colorScheme.errorContainer,
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    'Running low: ${low.map((i) => i.name).join(', ')}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              for (final item in items)
                ListTile(
                  title: Text(item.name),
                  subtitle: Text([
                    if (item.category.isNotEmpty) item.category,
                    if (item.minimumQuantity > 0)
                      'reorder at ${item.minimumQuantity}',
                  ].join(' · ')),
                  trailing: Text(
                    '${item.currentQuantity} ${item.unit}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: item.minimumQuantity > 0 &&
                              item.currentQuantity <= item.minimumQuantity
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                  onTap: () => _move(context, ref, item),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addItem(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final opening = TextEditingController(text: '0');
    final minimum = TextEditingController(text: '0');
    final unit = TextEditingController(text: 'pcs');

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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Add an item',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Item',
                hintText: 'A4 paper',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: opening,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'In stock now',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: unit,
                    decoration: const InputDecoration(
                      labelText: 'Unit',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: minimum,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Warn me below',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Add'),
              ),
            ),
          ],
        ),
      ),
    );

    if (saved != true || name.text.trim().isEmpty) return;
    await ref.read(inventoryServiceProvider).addItem(
          name: name.text.trim(),
          unit: unit.text.trim(),
          openingQuantity: int.tryParse(opening.text.trim()) ?? 0,
          minimumQuantity: int.tryParse(minimum.text.trim()) ?? 0,
        );
  }

  Future<void> _move(
    BuildContext context,
    WidgetRef ref,
    InventoryItem item,
  ) async {
    final quantity = TextEditingController(text: '1');
    final reason = TextEditingController();
    var move = StockMove.issue;

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
              Text('${item.name} — ${item.currentQuantity} ${item.unit}',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              SegmentedButton<StockMove>(
                segments: const [
                  ButtonSegment(value: StockMove.receive, label: Text('Received')),
                  ButtonSegment(value: StockMove.issue, label: Text('Given out')),
                  ButtonSegment(value: StockMove.damage, label: Text('Damaged')),
                ],
                selected: {move},
                onSelectionChanged: (v) => setSheet(() => move = v.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: quantity,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'How many ${item.unit}',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reason,
                decoration: const InputDecoration(
                  labelText: 'Why',
                  hintText: 'Model test printing',
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
    await ref.read(inventoryServiceProvider).move(
          item: item,
          move: move,
          quantity: int.tryParse(quantity.text.trim()) ?? 0,
          reason: reason.text.trim(),
        );
  }
}
