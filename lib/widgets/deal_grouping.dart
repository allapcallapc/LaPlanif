import 'package:flutter/material.dart';

import '../models/deal_item.dart';

/// The order category sections are listed in wherever deal items are shown
/// grouped - the deals list and the anchor picker share it so the same item
/// is always found in the same place.
const dealSectionOrder = [
  DealCategory.protein,
  DealCategory.vegetables,
  DealCategory.fruit,
  DealCategory.carbs,
  DealCategory.uncategorized,
];

/// Groups [items] by category, keyed in [dealSectionOrder] order with empty
/// categories left out. Each group keeps [items]' relative order.
Map<DealCategory, List<DealItem>> groupDealsByCategory(Iterable<DealItem> items) {
  final grouped = <DealCategory, List<DealItem>>{};
  for (final item in items) {
    grouped.putIfAbsent(item.category, () => []).add(item);
  }
  return {
    for (final category in dealSectionOrder)
      if ((grouped[category] ?? const []).isNotEmpty) category: grouped[category]!,
  };
}

/// Cover-page items (the flyer's featured deals) first, otherwise keeping
/// [items]' order.
List<DealItem> coverFirst(List<DealItem> items) => [
  ...items.where((item) => item.isCoverPage),
  ...items.where((item) => !item.isCoverPage),
];

class DealSectionHeader extends StatelessWidget {
  const DealSectionHeader(this.category, {super.key});

  final DealCategory category;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        category.label,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

class DealCoverBadge extends StatelessWidget {
  const DealCoverBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.shade100,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.amber.shade700),
      ),
      child: Text(
        'COVER',
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber.shade900),
      ),
    );
  }
}
