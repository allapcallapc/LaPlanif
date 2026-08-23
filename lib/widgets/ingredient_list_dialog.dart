import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/meal_plan_full.dart';

/// Shows the shopping list extracted from a week's [MealSlotFull]s, with a
/// one-tap copy of the plain-text version for pasting into a notes app.
Future<void> showIngredientListDialog(BuildContext context, List<MealSlotFull> slots) {
  final items = slots.shoppingList;
  return showDialog(context: context, builder: (_) => _IngredientListDialog(items: items));
}

String _itemLine(ShoppingListItem item) => item.amounts.isEmpty ? item.name : '${item.name} — ${item.amounts.join(', ')}';

class _IngredientListDialog extends StatelessWidget {
  const _IngredientListDialog({required this.items});

  final List<ShoppingListItem> items;

  void _copyToClipboard(BuildContext context) {
    final text = items.map((item) => '- ${_itemLine(item)}').join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ingredient list copied to clipboard.')));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ingredient list'),
      content: SizedBox(
        width: double.maxFinite,
        child: items.isEmpty
            ? const Text('No ingredients to list.')
            : ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (context, i) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.circle, size: 6),
                  title: Text(_itemLine(items[i])),
                ),
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
