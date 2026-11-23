import 'package:flutter/material.dart';

import '../models/deal_item.dart';
import '../models/meal_plan_preview.dart';

/// Common carbs most kitchens keep on hand - offered for every meal whether
/// or not anything starchy is on sale this week.
const pantryCarbs = [
  'Basmati rice',
  'Jasmine rice',
  'Brown rice',
  'Quinoa',
  'Couscous',
  'Pasta',
  'Egg noodles',
  'Rice noodles',
  'Potatoes',
  'Sweet potatoes',
  'Bulgur',
  'Orzo',
  'Barley',
  'Tortillas',
  'Naan',
];

/// Lets the user pick a meal's carb: a pantry staple, anything else typed
/// in (also treated as a pantry item), or one of this week's carb [deals].
/// [usedElsewhere] holds lower-cased names other meals already use - still
/// selectable (the same carb twice is allowed), just flagged. Resolves to
/// the chosen carb, or null on cancel.
Future<AnchorItem?> showCarbPickerDialog(
  BuildContext context, {
  required List<DealItem> deals,
  Set<String> usedElsewhere = const {},
}) {
  return showDialog<AnchorItem>(
    context: context,
    builder: (_) => CarbPickerDialog(deals: deals, usedElsewhere: usedElsewhere),
  );
}

class CarbPickerDialog extends StatefulWidget {
  const CarbPickerDialog({super.key, required this.deals, this.usedElsewhere = const {}});

  final List<DealItem> deals;
  final Set<String> usedElsewhere;

  @override
  State<CarbPickerDialog> createState() => _CarbPickerDialogState();
}

class _CarbPickerDialogState extends State<CarbPickerDialog> {
  final _customController = TextEditingController();

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  bool _isUsed(String name) => widget.usedElsewhere.contains(name.trim().toLowerCase());

  void _submitCustom() {
    final name = _customController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(AnchorItem.pantry(name));
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: size.height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text('Choose a carb', style: textTheme.headlineSmall),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.deals.isNotEmpty) ...[
                      Text('On sale this week', style: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold)),
                      for (final deal in widget.deals)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          onTap: () =>
                              Navigator.of(context)
                                  .pop(AnchorItem(name: deal.name, store: deal.storeName, role: AnchorRole.carb)),
                          leading: deal.preference == DealPreference.priority
                              ? Icon(Icons.star, color: Theme.of(context).colorScheme.primary)
                              : const Icon(Icons.local_offer_outlined),
                          title: Text(deal.name),
                          subtitle: Text(_isUsed(deal.name) ? '${deal.storeName} · in another meal' : deal.storeName),
                          trailing: Text(deal.priceText, style: const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      const SizedBox(height: 12),
                    ],
                    Text('From the pantry', style: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final name in pantryCarbs)
                          ActionChip(
                            avatar: Icon(_isUsed(name) ? Icons.repeat : Icons.kitchen_outlined, size: 16),
                            label: Text(name),
                            tooltip: _isUsed(name) ? 'Already in another meal' : null,
                            visualDensity: VisualDensity.compact,
                            onPressed: () => Navigator.of(context).pop(AnchorItem.pantry(name)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _customController,
                            decoration: const InputDecoration(
                              hintText: 'Something else (e.g. polenta)',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _submitCustom(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(onPressed: _submitCustom, child: const Text('Use')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
