import '../models/deal_item.dart';
import '../models/meal_plan_full.dart';
import '../models/meal_plan_preview.dart';

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
///   names a real, non-excluded item from this week's [deals] (matched by
///   name, with the store taken from the deal itself if the AI got it
///   wrong) - a recipe can pick up a vegetable that happens to be on sale,
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
  final dealsByKey = <String, List<DealItem>>{};
  for (final deal in deals) {
    if (deal.preference == DealPreference.excluded) continue;
    dealsByKey.putIfAbsent(_nameKey(deal.name), () => []).add(deal);
  }

  AnchorItem? resolve(AnchorItem item) {
    final key = _nameKey(item.name);
    if (anchorKeys.contains(key)) {
      return anchors.firstWhere((anchor) => _nameKey(anchor.name) == key);
    }
    final matches = dealsByKey[key];
    if (matches == null) return null;
    final sameStore = matches.where((deal) => _nameKey(deal.storeName) == _nameKey(item.store));
    final deal = sameStore.isNotEmpty ? sameStore.first : matches.first;
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
