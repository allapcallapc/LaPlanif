import 'meal_plan_config.dart';

/// One candidate deal item anchoring a slot's batch-cooked recipe - the main
/// protein or a key supporting ingredient.
class AnchorItem {
  const AnchorItem({required this.name, required this.store});

  final String name;
  final String store;
}

/// The AI's proposed direction for one [MealSlot]'s batch-cooked recipe: a
/// non-binding checkpoint before full recipe generation - no recipe name or
/// instructions yet, just which deal items anchor it and a one-line note on
/// where it's headed.
class MealSlotPreview {
  const MealSlotPreview({
    required this.mealType,
    required this.protein,
    required this.count,
    required this.portionsPerMeal,
    required this.anchorItems,
    required this.note,
  });

  final MealType mealType;
  final String protein;
  final int count;
  final int portionsPerMeal;
  final List<AnchorItem> anchorItems;
  final String note;

  /// A slot is ONE recipe, batch-cooked once, that has to yield enough for
  /// every meal instance in the slot - not one recipe per instance.
  int get totalPortionsNeeded => count * portionsPerMeal;

  MealSlotPreview copyWith({List<AnchorItem>? anchorItems}) => MealSlotPreview(
    mealType: mealType,
    protein: protein,
    count: count,
    portionsPerMeal: portionsPerMeal,
    anchorItems: anchorItems ?? this.anchorItems,
    note: note,
  );
}

class MealPlanPreview {
  const MealPlanPreview({required this.slots});

  final List<MealSlotPreview> slots;
}
