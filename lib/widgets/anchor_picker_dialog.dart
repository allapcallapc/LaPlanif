import 'package:flutter/material.dart';

import '../models/deal_item.dart';
import '../models/meal_plan_preview.dart';
import 'deal_grouping.dart';

/// Lets the user pick one of [items] as a meal's anchor. Laid out like the
/// deals list - grouped by category, filterable by store and category - plus
/// a name search, since a full week of flyers is far too long to scan as one
/// flat list. [initialCategory] preselects a category filter (still
/// changeable, since the flyer's categories aren't always right). Resolves
/// to the picked item, or null on cancel.
Future<DealItem?> showAnchorPickerDialog(
  BuildContext context, {
  required List<DealItem> items,
  required String title,
  DealCategory? initialCategory,
}) {
  return showDialog<DealItem>(
    context: context,
    builder: (_) => AnchorPickerDialog(items: items, title: title, initialCategory: initialCategory),
  );
}

/// The same picker for one part of a meal ([role]), which also lets the
/// user type in an ingredient that isn't on sale. Resolves to the chosen
/// deal or typed ingredient as that part of the meal, or null on cancel.
Future<AnchorItem?> showIngredientPickerDialog(
  BuildContext context, {
  required List<DealItem> items,
  required String title,
  required AnchorRole role,
  DealCategory? initialCategory,
}) async {
  final picked = await showDialog<Object>(
    context: context,
    builder: (_) => AnchorPickerDialog(items: items, title: title, initialCategory: initialCategory, allowCustom: true),
  );
  return switch (picked) {
    DealItem deal => AnchorItem(name: deal.name, store: deal.storeName, role: role),
    String name => AnchorItem.pantry(name, role: role),
    _ => null,
  };
}

class AnchorPickerDialog extends StatefulWidget {
  const AnchorPickerDialog({
    super.key,
    required this.items,
    required this.title,
    this.initialCategory,
    this.allowCustom = false,
  });

  final List<DealItem> items;
  final String title;
  final DealCategory? initialCategory;

  /// Adds a field for typing an ingredient that isn't on sale; the dialog
  /// then closes with that name (a String) instead of a [DealItem].
  final bool allowCustom;

  @override
  State<AnchorPickerDialog> createState() => _AnchorPickerDialogState();
}

class _AnchorPickerDialogState extends State<AnchorPickerDialog> {
  String? _storeFilter;
  late DealCategory? _categoryFilter = widget.initialCategory;
  String _query = '';
  final _customController = TextEditingController();

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  void _submitCustom() {
    final name = _customController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  List<String> get _storeNames => widget.items.map((item) => item.storeName).toSet().toList()..sort();

  List<DealItem> get _storeFiltered =>
      _storeFilter == null ? widget.items : widget.items.where((item) => item.storeName == _storeFilter).toList();

  List<DealItem> _filtered(DealCategory? categoryFilter) {
    final query = _query.trim().toLowerCase();
    return _storeFiltered
        .where((item) => categoryFilter == null || item.category == categoryFilter)
        .where((item) => query.isEmpty || item.name.toLowerCase().contains(query))
        .toList();
  }

  // Priority items first (they're the ones the user already said they want
  // to use), then the flyer's cover deals, then everything else.
  List<DealItem> _sorted(List<DealItem> items) => [
    ...items.where((item) => item.preference == DealPreference.priority),
    ...coverFirst(items.where((item) => item.preference != DealPreference.priority).toList()),
  ];

  @override
  Widget build(BuildContext context) {
    final storeNames = _storeNames;
    final availableCategories = groupDealsByCategory(_storeFiltered).keys.toList();
    // A store change can leave the picked category with nothing in it - fall
    // back to "All" rather than showing an unexplained empty list.
    final categoryFilter = availableCategories.contains(_categoryFilter) ? _categoryFilter : null;
    final grouped = groupDealsByCategory(_filtered(categoryFilter));
    final rows = <Widget>[
      for (final MapEntry(key: category, value: items) in grouped.entries) ...[
        DealSectionHeader(category),
        ..._sorted(items).map(_buildItemTile),
      ],
    ];

    final size = MediaQuery.sizeOf(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: size.height * 0.85),
        child: SizedBox(
          width: double.maxFinite,
          height: double.maxFinite,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                child: Text(widget.title, style: Theme.of(context).textTheme.headlineSmall),
              ),
              if (widget.items.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search deals',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                if (storeNames.length > 1)
                  _buildChipRow([
                    _buildChip('All stores', _storeFilter == null, () => _storeFilter = null),
                    for (final name in storeNames) _buildChip(name, _storeFilter == name, () => _storeFilter = name),
                  ]),
                if (availableCategories.length > 1)
                  _buildChipRow([
                    _buildChip('All', categoryFilter == null, () => _categoryFilter = null),
                    for (final category in availableCategories)
                      _buildChip(category.label, categoryFilter == category, () => _categoryFilter = category),
                  ]),
                const SizedBox(height: 4),
                const Divider(height: 1),
              ],
              Expanded(
                child: widget.items.isEmpty
                    ? const Padding(padding: EdgeInsets.all(24), child: Text('No available deal items.'))
                    : rows.isEmpty
                    ? const Center(child: Text('No items match the current filters.'))
                    : ListView(children: rows),
              ),
              const Divider(height: 1),
              if (widget.allowCustom)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _customController,
                          decoration: const InputDecoration(
                            hintText: 'Not on sale? Type an ingredient',
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
                ),
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
      ),
    );
  }

  // Scrolls sideways rather than wrapping, so a long store list doesn't eat
  // into the room left for the items themselves.
  Widget _buildChipRow(List<Widget> chips) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [for (final chip in chips) Padding(padding: const EdgeInsets.only(right: 8), child: chip)],
      ),
    );
  }

  Widget _buildChip(String label, bool selected, VoidCallback select) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => setState(select),
    );
  }

  Widget _buildItemTile(DealItem item) {
    final isPriority = item.preference == DealPreference.priority;
    return ListTile(
      onTap: () => Navigator.of(context).pop(item),
      leading: isPriority ? Icon(Icons.star, color: Theme.of(context).colorScheme.primary) : null,
      title: Row(
        children: [
          Flexible(child: Text(item.name)),
          if (item.isCoverPage) ...[const SizedBox(width: 8), const DealCoverBadge()],
        ],
      ),
      subtitle: Text(item.storeName),
      trailing: Text(item.priceText, style: const TextStyle(fontWeight: FontWeight.bold)),
    );
  }
}
