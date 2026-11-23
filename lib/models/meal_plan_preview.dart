import 'meal_plan_config.dart';

/// One ingredient a slot's batch-cooked recipe is built around: a deal item
/// (the main protein, a vegetable or carb side), or - for the carb only - a
/// pantry staple such as rice, quinoa or couscous, which isn't on sale
/// anywhere ([isPantry], with [store] set to [pantryStore]).
///
/// Which item is the meal's carb is stated explicitly ([isCarb]) - set by
/// the AI's suggestion or by the user's pick in the carb picker - rather
/// than inferred from the flyer's category, which the deal extraction can
/// get wrong (e.g. tofu filed under Carbs).
class AnchorItem {
  const AnchorItem({required this.name, required this.store, this.isPantry = false, bool isCarb = false})
    : isCarb = isCarb || isPantry;

  /// A pantry carb: not a deal item, so it never appears among a recipe's
  /// deal items or the shopping list's deals.
  const AnchorItem.pantry(this.name) : store = pantryStore, isPantry = true, isCarb = true;

  static const pantryStore = 'Pantry';

  final String name;
  final String store;
  final bool isPantry;

  /// Whether this is the meal's carb. Always true for a pantry item.
  final bool isCarb;

  // `pantry`/`carb` are only written when true, so plain deal-item JSON (and
  // anything saved before carbs were tracked) is unchanged.
  Map<String, dynamic> toJson() => {
    'name': name,
    'store': store,
    if (isPantry) 'pantry': true,
    if (isCarb && !isPantry) 'carb': true,
  };

  factory AnchorItem.fromJson(Map<String, dynamic> json) => AnchorItem(
    name: json['name'] as String,
    store: json['store'] as String,
    isPantry: json['pantry'] as bool? ?? false,
    isCarb: json['carb'] as bool? ?? false,
  );
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

  Map<String, dynamic> toJson() => {
    'mealType': mealType.name,
    'protein': protein,
    'count': count,
    'portionsPerMeal': portionsPerMeal,
    'anchorItems': anchorItems.map((a) => a.toJson()).toList(),
    'note': note,
  };

  factory MealSlotPreview.fromJson(Map<String, dynamic> json) => MealSlotPreview(
    mealType: MealType.fromName(json['mealType'] as String),
    protein: json['protein'] as String,
    count: json['count'] as int,
    portionsPerMeal: json['portionsPerMeal'] as int,
    anchorItems: (json['anchorItems'] as List<dynamic>)
        .map((a) => AnchorItem.fromJson(a as Map<String, dynamic>))
        .toList(),
    note: json['note'] as String,
  );
}

class MealPlanPreview {
  const MealPlanPreview({required this.slots});

  final List<MealSlotPreview> slots;

  Map<String, dynamic> toJson() => {'slots': slots.map((s) => s.toJson()).toList()};

  factory MealPlanPreview.fromJson(Map<String, dynamic> json) => MealPlanPreview(
    slots: (json['slots'] as List<dynamic>).map((s) => MealSlotPreview.fromJson(s as Map<String, dynamic>)).toList(),
  );
}
