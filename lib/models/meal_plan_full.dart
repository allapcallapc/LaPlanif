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

  Map<String, dynamic> toJson() => {'name': name, 'amount': amount};

  factory Ingredient.fromJson(Map<String, dynamic> json) =>
      Ingredient(name: json['name'] as String, amount: json['amount'] as String);
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

  Map<String, dynamic> toJson() => {
    'type': type.value,
    'name': name,
    'recipeUrl': recipeUrl,
    'ingredients': ingredients.map((i) => i.toJson()).toList(),
    'instructions': instructions,
    'note': note,
    'usesWeeklyDeal': usesWeeklyDeal,
    'dealItems': dealItems.map((d) => d.toJson()).toList(),
  };

  factory MealComponent.fromJson(Map<String, dynamic> json) => MealComponent(
    type: MealComponentType.fromValue(json['type'] as String),
    name: json['name'] as String,
    recipeUrl: json['recipeUrl'] as String?,
    ingredients: (json['ingredients'] as List<dynamic>? ?? const [])
        .map((i) => Ingredient.fromJson(i as Map<String, dynamic>))
        .toList(),
    instructions: (json['instructions'] as List<dynamic>? ?? const []).cast<String>(),
    note: json['note'] as String? ?? '',
    usesWeeklyDeal: json['usesWeeklyDeal'] as bool,
    dealItems: (json['dealItems'] as List<dynamic>? ?? const [])
        .map((d) => AnchorItem.fromJson(d as Map<String, dynamic>))
        .toList(),
  );
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

  /// The recipe name for this slot - the batch-cooked recipe is built around
  /// its protein, so the protein component's name stands in for the slot's
  /// overall recipe name (matches how the full-plan card already leads with
  /// the protein component).
  String get recipeName => proteinComponent.name;

  /// Every deal item this slot draws on, across all three components,
  /// deduped by name+store - used as the diversity-window lookup key for
  /// history entries so the same anchor isn't counted twice just because two
  /// components happened to share it.
  List<AnchorItem> get dealItemsUsed {
    final seen = <String>{};
    final result = <AnchorItem>[];
    for (final component in [proteinComponent, carbComponent, vegetableComponent]) {
      if (!component.usesWeeklyDeal) continue;
      for (final item in component.dealItems) {
        final key = '${item.name.trim().toLowerCase()}::${item.store.trim().toLowerCase()}';
        if (seen.add(key)) result.add(item);
      }
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
    'mealType': mealType.name,
    'protein': protein,
    'count': count,
    'portionsPerMeal': portionsPerMeal,
    'proteinComponent': proteinComponent.toJson(),
    'carbComponent': carbComponent.toJson(),
    'vegetableComponent': vegetableComponent.toJson(),
  };

  factory MealSlotFull.fromJson(Map<String, dynamic> json) => MealSlotFull(
    mealType: MealType.fromName(json['mealType'] as String),
    protein: json['protein'] as String,
    count: json['count'] as int,
    portionsPerMeal: json['portionsPerMeal'] as int,
    proteinComponent: MealComponent.fromJson(json['proteinComponent'] as Map<String, dynamic>),
    carbComponent: MealComponent.fromJson(json['carbComponent'] as Map<String, dynamic>),
    vegetableComponent: MealComponent.fromJson(json['vegetableComponent'] as Map<String, dynamic>),
  );

  MealSlotFull copyWith({MealComponent? proteinComponent, MealComponent? carbComponent, MealComponent? vegetableComponent}) =>
      MealSlotFull(
        mealType: mealType,
        protein: protein,
        count: count,
        portionsPerMeal: portionsPerMeal,
        proteinComponent: proteinComponent ?? this.proteinComponent,
        carbComponent: carbComponent ?? this.carbComponent,
        vegetableComponent: vegetableComponent ?? this.vegetableComponent,
      );
}

class MealPlanFull {
  const MealPlanFull({required this.slots});

  final List<MealSlotFull> slots;

  /// The consolidated shopping list for this week's plan - see
  /// [MealSlotFullListShoppingList.shoppingList].
  List<ShoppingListItem> get shoppingList => slots.shoppingList;
}

/// One consolidated shopping-list line: an ingredient name plus every amount
/// it's needed in across the week, combined when the same ingredient is
/// used by more than one recipe.
class ShoppingListItem {
  const ShoppingListItem({required this.name, required this.amounts});

  final String name;

  /// Every distinct, non-empty amount this ingredient was requested in,
  /// deduplicated but not summed (amounts are free-form strings like
  /// "2 cups", not always safe to add together).
  final List<String> amounts;
}

/// Extracts a shopping list from a week's worth of [MealSlotFull]s: every
/// recipe ingredient, plus one line per simple-side component (which has no
/// structured ingredients of its own - the component's name is the item to
/// buy), deduplicated by name across the whole week.
extension MealSlotFullListShoppingList on List<MealSlotFull> {
  List<ShoppingListItem> get shoppingList {
    final amountsByKey = <String, List<String>>{};
    final displayNameByKey = <String, String>{};

    void addIngredient(String name, String amount) {
      final trimmedName = name.trim();
      if (trimmedName.isEmpty) return;
      final key = trimmedName.toLowerCase();
      displayNameByKey.putIfAbsent(key, () => trimmedName);
      final amounts = amountsByKey.putIfAbsent(key, () => []);
      final trimmedAmount = amount.trim();
      if (trimmedAmount.isNotEmpty && !amounts.contains(trimmedAmount)) {
        amounts.add(trimmedAmount);
      }
    }

    for (final slot in this) {
      for (final component in [slot.proteinComponent, slot.carbComponent, slot.vegetableComponent]) {
        // Already covered by the protein component's own ingredients above -
        // listing it again here would double it on the shopping list.
        if (component.type == MealComponentType.coveredByProtein) continue;
        if (component.ingredients.isNotEmpty) {
          for (final ingredient in component.ingredients) {
            addIngredient(ingredient.name, ingredient.amount);
          }
        } else {
          addIngredient(component.name, '');
        }
      }
    }

    final keys = amountsByKey.keys.toList()..sort((a, b) => displayNameByKey[a]!.compareTo(displayNameByKey[b]!));
    return [for (final key in keys) ShoppingListItem(name: displayNameByKey[key]!, amounts: amountsByKey[key]!)];
  }
}
