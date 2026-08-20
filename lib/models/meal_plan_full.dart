import 'meal_plan_config.dart';
import 'meal_plan_preview.dart';

/// How a [MealComponent] was resolved.
enum MealComponentType {
  /// A real, search-verified recipe URL.
  link,

  /// A full AI-authored recipe (ingredients + instructions), used when no
  /// verified link could be found.
  aiRecipe,

  /// No full recipe needed - just a short prep note (e.g. "steamed broccoli
  /// with butter").
  simpleSide,

  /// This component is already explicitly covered by the protein's chosen
  /// recipe (an actual ingredient prepared as part of it, not just a
  /// "serve with X" suggestion) - see [MealComponent.recipeUrl], which
  /// points at the same recipe as the protein component in this case.
  coveredByProtein;

  String get value => switch (this) {
    MealComponentType.link => 'link',
    MealComponentType.aiRecipe => 'ai_recipe',
    MealComponentType.simpleSide => 'simple_side',
    MealComponentType.coveredByProtein => 'covered_by_protein',
  };

  static MealComponentType fromValue(String value) => switch (value.trim()) {
    'link' => MealComponentType.link,
    'ai_recipe' => MealComponentType.aiRecipe,
    'simple_side' => MealComponentType.simpleSide,
    'covered_by_protein' => MealComponentType.coveredByProtein,
    _ => throw ArgumentError('Unknown meal component type: $value'),
  };
}

/// One ingredient line, scaled to the slot's total portions needed.
class Ingredient {
  const Ingredient({required this.name, required this.amount});

  final String name;
  final String amount;
}

/// One of a [MealSlotFull]'s three components (protein, carb, vegetable).
class MealComponent {
  const MealComponent({
    required this.type,
    required this.name,
    this.recipeUrl,
    this.ingredients = const [],
    this.instructions = const [],
    this.note = '',
    required this.usesWeeklyDeal,
    this.dealItems = const [],
  });

  final MealComponentType type;
  final String name;

  /// A verified recipe URL - set for [MealComponentType.link], and for
  /// [MealComponentType.coveredByProtein] (pointing at the same recipe as
  /// the protein component). Null otherwise.
  final String? recipeUrl;

  /// Populated for [MealComponentType.aiRecipe] (and optionally
  /// [MealComponentType.link]); empty otherwise.
  final List<Ingredient> ingredients;

  /// Populated for [MealComponentType.aiRecipe]; empty otherwise.
  final List<String> instructions;

  /// A short prep note - the whole point of [MealComponentType.simpleSide],
  /// and optionally used elsewhere for extra context.
  final String note;

  /// Whether this component draws on one of this week's deal items.
  final bool usesWeeklyDeal;

  /// The deal item(s) this component draws on, when [usesWeeklyDeal] is true.
  final List<AnchorItem> dealItems;
}

/// One fully generated meal: a batch-cooked recipe (protein + carb +
/// vegetable) covering every meal instance in the confirmed [MealSlotPreview]
/// it was generated from.
class MealSlotFull {
  const MealSlotFull({
    required this.mealType,
    required this.protein,
    required this.count,
    required this.portionsPerMeal,
    required this.proteinComponent,
    required this.carbComponent,
    required this.vegetableComponent,
  });

  final MealType mealType;
  final String protein;
  final int count;
  final int portionsPerMeal;
  final MealComponent proteinComponent;
  final MealComponent carbComponent;
  final MealComponent vegetableComponent;

  int get totalPortionsNeeded => count * portionsPerMeal;
}

class MealPlanFull {
  const MealPlanFull({required this.slots});

  final List<MealSlotFull> slots;
}
