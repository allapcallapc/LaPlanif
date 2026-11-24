import '../models/deal_item.dart';
import '../models/meal_plan_full.dart';
import '../models/meal_plan_preview.dart';
import 'deal_matching.dart';

String _nameKey(String name) => name.trim().toLowerCase();

/// Squares a freshly generated recipe with the deal items the user confirmed
/// on the ingredients step, so the recipe step can only ever ADD deal items,
/// never take one away:
///
/// - Every confirmed anchor stays on the meal. One the AI didn't attribute to
///   any component is attached to the protein component (the dish the meal
///   is built around), so it still lands in the shopping list's deals
///   section instead of silently vanishing.
/// - Any other deal item the AI says a component uses is kept only when it
///   names a real, non-excluded item from this week's [deals] (matched
///   loosely by name - see findDeal - with the name and store taken from
///   the deal itself) - a recipe can pick up a vegetable that happens to be on sale,
///   but can't invent a deal or bring back one the user excluded.
/// - A pantry carb anchor isn't a deal item, so it's never listed among a
///   component's deal items (the recipe's own ingredients cover it).
MealSlotFull reconcileRecipeDealItems({
  required MealSlotFull recipe,
  required List<AnchorItem> anchors,
  required List<DealItem> deals,
}) {
  anchors = anchors.where((anchor) => !anchor.isPantry).toList();
  final anchorKeys = {for (final anchor in anchors) _nameKey(anchor.name)};
  final available = deals.where((deal) => deal.preference != DealPreference.excluded).toList();

  // What a recipe's deal item refers to: one of the confirmed anchors, or a
  // real, non-excluded deal - matched loosely (see findDeal), since the AI
  // often shortens or rewords flyer names. Null drops it.
  AnchorItem? resolve(AnchorItem item) {
    final key = _nameKey(item.name);
    if (anchorKeys.contains(key)) {
      return anchors.firstWhere((anchor) => _nameKey(anchor.name) == key);
    }
    final deal = findDeal(item.name, item.store, available);
    if (deal == null) return null;
    final dealKey = _nameKey(deal.name);
    if (anchorKeys.contains(dealKey)) {
      return anchors.firstWhere((anchor) => _nameKey(anchor.name) == dealKey);
    }
    return AnchorItem(name: deal.name, store: deal.storeName);
  }

  final seen = <String>{};
  MealComponent clean(MealComponent component, {List<AnchorItem> extra = const []}) {
    final items = <AnchorItem>[];
    for (final item in [if (component.usesWeeklyDeal) ...component.dealItems, ...extra]) {
      final resolved = resolve(item);
      if (resolved == null) continue;
      // One deal item belongs to one component - the first one that claims
      // it - so it isn't counted twice on the card.
      if (seen.add(_nameKey(resolved.name))) items.add(resolved);
    }
    return _withDealItems(component, items);
  }

  // Cleaned in card order, carb and vegetable first, so an anchor that the AI
  // correctly put on a side isn't then also claimed by the protein below.
  final carb = clean(recipe.carbComponent);
  final vegetable = clean(recipe.vegetableComponent);
  final claimedByProtein = recipe.proteinComponent.usesWeeklyDeal
      ? recipe.proteinComponent.dealItems.map((item) => _nameKey(item.name)).toSet()
      : <String>{};
  final missingAnchors = anchors.where((anchor) {
    final key = _nameKey(anchor.name);
    return !seen.contains(key) && !claimedByProtein.contains(key);
  }).toList();
  final protein = clean(recipe.proteinComponent, extra: missingAnchors);

  return recipe.copyWith(proteinComponent: protein, carbComponent: carb, vegetableComponent: vegetable);
}

/// The deal items [recipe] uses that weren't among the confirmed [anchors] -
/// what the recipe step added on its own.
List<AnchorItem> addedDealItems(MealSlotFull recipe, List<AnchorItem> anchors) {
  final anchorKeys = {for (final anchor in anchors) _nameKey(anchor.name)};
  return recipe.dealItemsUsed.where((item) => !anchorKeys.contains(_nameKey(item.name))).toList();
}

MealComponent _withDealItems(MealComponent component, List<AnchorItem> dealItems) => MealComponent(
  type: component.type,
  name: component.name,
  recipeUrl: component.recipeUrl,
  recipeSourceTitle: component.recipeSourceTitle,
  ingredients: component.ingredients,
  instructions: component.instructions,
  note: component.note,
  usesWeeklyDeal: dealItems.isNotEmpty,
  dealItems: dealItems,
);
