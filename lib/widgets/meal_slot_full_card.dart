import 'package:flutter/material.dart';

import '../models/meal_plan_config.dart';
import '../models/meal_plan_full.dart';
import '../models/meal_plan_preview.dart';

/// Renders one [MealSlotFull] the same way on both the full-plan view and
/// the History screen: header (meal type, protein, portions), then a
/// protein/carb/vegetable breakdown. [trailing] lets a caller (e.g. the
/// History screen's edit affordances) add extra header controls without
/// this widget needing to know about editing.
class MealSlotFullCard extends StatelessWidget {
  const MealSlotFullCard({super.key, required this.slot, this.onOpenRecipeLink, this.trailing});

  final MealSlotFull slot;
  final void Function(String url)? onOpenRecipeLink;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(slot.mealType == MealType.lunch ? Icons.wb_sunny_outlined : Icons.nightlight_outlined, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${_capitalize(slot.mealType.name)} · ${slot.protein}',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Chip(
                  label: Text('${slot.totalPortionsNeeded} portions'),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 2),
            Text('${slot.count} meals × ${slot.portionsPerMeal} portions', style: Theme.of(context).textTheme.bodySmall),
            const Divider(height: 20),
            _buildComponentBlock(context, 'Protein', slot.proteinComponent),
            const Divider(height: 20),
            _buildComponentBlock(context, 'Carb', slot.carbComponent, coveredNoun: 'carb'),
            const Divider(height: 20),
            _buildComponentBlock(context, 'Vegetable', slot.vegetableComponent, coveredNoun: 'vegetable'),
          ],
        ),
      ),
    );
  }

  // covered_by_protein components are merged into the protein section
  // instead of getting their own redundant sub-section - there's nothing
  // else to show for them beyond a pointer back up to the protein recipe.
  Widget _buildComponentBlock(BuildContext context, String label, MealComponent component, {String? coveredNoun}) {
    if (component.type == MealComponentType.coveredByProtein) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(Icons.merge_type, size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'This recipe already includes the ${coveredNoun ?? label.toLowerCase()} — see above.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ),
      );
    }
    return _buildComponentSection(context, label, component);
  }

  Widget _buildComponentSection(BuildContext context, String label, MealComponent component) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            _buildTypeChip(component.type),
            if (component.usesWeeklyDeal) _buildDealBadge(),
          ],
        ),
        const SizedBox(height: 4),
        Text(component.name, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        if (component.recipeUrl != null) _buildRecipeLink(context, component.recipeUrl!),
        if (component.type == MealComponentType.simpleSide && component.note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(component.note, style: Theme.of(context).textTheme.bodySmall),
          ),
        if (component.type == MealComponentType.aiRecipe) ...[
          if (component.ingredients.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Ingredients', style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold)),
            for (final ingredient in component.ingredients)
              Text('• ${ingredient.name} — ${ingredient.amount}', style: Theme.of(context).textTheme.bodySmall),
          ],
          if (component.instructions.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Steps', style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold)),
            for (final entry in component.instructions.asMap().entries)
              Text('${entry.key + 1}. ${entry.value}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
        if (component.usesWeeklyDeal && component.dealItems.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: component.dealItems.map(_buildDealItemChip).toList()),
        ],
      ],
    );
  }

  // Only ever called for link/aiRecipe/simpleSide: _buildComponentBlock
  // intercepts coveredByProtein before delegating here, so that case isn't
  // handled - a fourth chip label for it would be dead code.
  Widget _buildTypeChip(MealComponentType type) {
    final (label, icon) = type == MealComponentType.link
        ? ('Recipe link', Icons.link)
        : type == MealComponentType.aiRecipe
        ? ('AI recipe', Icons.auto_awesome)
        : ('Simple side', Icons.eco_outlined);
    return Chip(
      avatar: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _buildDealBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.green.shade100,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.green.shade700),
      ),
      child: Text(
        "This week's deal",
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.green.shade900),
      ),
    );
  }

  Widget _buildDealItemChip(AnchorItem item) {
    return Chip(
      avatar: const Icon(Icons.local_offer_outlined, size: 14),
      label: Text('${item.name} · ${item.store}', style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _buildRecipeLink(BuildContext context, String url) {
    final launcher = onOpenRecipeLink;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: launcher == null ? null : () => launcher(url),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.open_in_new, size: 14, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                url,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  decoration: TextDecoration.underline,
                  fontSize: 12,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}
