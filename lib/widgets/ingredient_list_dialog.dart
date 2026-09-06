import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/meal_plan_full.dart';
import '../models/meal_plan_preview.dart';
import '../utils/grocery_category.dart';

/// Shows the shopping list extracted from a week's [MealSlotFull]s, grouped
/// by aisle with this week's deal items called out up top, plus a one-tap
/// copy of the plain-text version for pasting into a notes app.
Future<void> showIngredientListDialog(BuildContext context, List<MealSlotFull> slots) {
  final items = slots.shoppingList;
  final deals = slots.dealItemsUsed;
  return showDialog(context: context, builder: (_) => _IngredientListDialog(items: items, deals: deals));
}

String _itemLine(ShoppingListItem item) => item.amounts.isEmpty ? item.name : '${item.name} — ${item.amounts.join(', ')}';

class _IngredientListDialog extends StatelessWidget {
  const _IngredientListDialog({required this.items, required this.deals});

  final List<ShoppingListItem> items;
  final List<AnchorItem> deals;

  List<ShoppingListItem> _itemsIn(GroceryCategory category) => items.where((i) => i.category == category).toList();

  void _copyToClipboard(BuildContext context) {
    final lines = <String>[];
    if (deals.isNotEmpty) {
      lines.add('ON SALE THIS WEEK');
      lines.addAll(deals.map((d) => '- ${d.name} (${d.store})'));
    }
    for (final category in GroceryCategory.values) {
      final categoryItems = _itemsIn(category);
      if (categoryItems.isEmpty) continue;
      if (lines.isNotEmpty) lines.add('');
      lines.add(category.label.toUpperCase());
      lines.addAll(categoryItems.map((item) => '- ${_itemLine(item)}'));
    }
    Clipboard.setData(ClipboardData(text: lines.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ingredient list copied to clipboard.')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sectionTitleStyle = theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.primary);

    return AlertDialog(
      title: const Text('Ingredient list'),
      content: SizedBox(
        width: double.maxFinite,
        child: items.isEmpty
            ? const Text('No ingredients to list.')
            : ListView(
                shrinkWrap: true,
                children: [
                  if (deals.isNotEmpty) ...[
                    Text('On sale this week', style: sectionTitleStyle),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final deal in deals)
                          Chip(
                            avatar: const Icon(Icons.local_offer, size: 14),
                            label: Text('${deal.name} · ${deal.store}'),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const Divider(height: 20),
                  ],
                  for (final category in GroceryCategory.values)
                    if (_itemsIn(category).isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 2),
                        child: Text(category.label, style: sectionTitleStyle),
                      ),
                      for (final item in _itemsIn(category))
                        ListTile(
                          dense: true,
                          leading: Icon(
                            item.isDealItem ? Icons.local_offer : Icons.circle,
                            size: item.isDealItem ? 14 : 6,
                            color: item.isDealItem ? theme.colorScheme.primary : null,
                          ),
                          title: Text(_itemLine(item)),
                        ),
                    ],
                ],
              ),
      ),
      actions: [
        if (items.isNotEmpty)
          TextButton.icon(
            onPressed: () => _copyToClipboard(context),
            icon: const Icon(Icons.copy_outlined, size: 18),
            label: const Text('Copy'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}
