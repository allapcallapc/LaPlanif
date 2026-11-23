import 'meal_plan_config.dart';

/// Which part of the meal an [AnchorItem] is.
enum AnchorRole {
  protein,
  carb,
  vegetable,

  /// Anything else the meal is built around (e.g. a sauce or cheese deal).
  other;

  static AnchorRole? fromName(String? name) => AnchorRole.values.where((role) => role.name == name).firstOrNull;
}

/// One ingredient a slot's batch-cooked recipe is built around: a deal item,
/// or something that isn't on sale - a pantry staple such as rice, quinoa
/// or couscous, or any ingredient the user typed in ([isPantry], with
/// [store] set to [pantryStore]).
///
/// Its part of the meal ([role]) is stated explicitly - set by the AI's
/// suggestion or by the picker the user chose it from - rather than inferred
/// from the flyer's category, which the deal extraction can get wrong (e.g.
/// tofu filed under Carbs). Null only for items saved before roles existed.
class AnchorItem {
  const AnchorItem({required this.name, required this.store, this.isPantry = false, AnchorRole? role})
    : role = role ?? (isPantry ? AnchorRole.carb : null);

  /// An ingredient that isn't a deal item (a carb unless [role] says
  /// otherwise), so it never appears among a recipe's deal items or the
  /// shopping list's deals.
  const AnchorItem.pantry(this.name, {AnchorRole this.role = AnchorRole.carb}) : store = pantryStore, isPantry = true;

  static const pantryStore = 'Pantry';

  final String name;
  final String store;
  final bool isPantry;
  final AnchorRole? role;

  /// Whether this is the meal's carb. Always true for a pantry item.
  bool get isCarb => role == AnchorRole.carb;

  // `pantry`/`role` are only written when set, so plain deal-item JSON (e.g.
  // in saved history) is unchanged.
  Map<String, dynamic> toJson() => {
    'name': name,
    'store': store,
    if (isPantry) 'pantry': true,
    // A non-deal item is a carb unless it says otherwise.
    if (role != null && !(isPantry && role == AnchorRole.carb)) 'role': role!.name,
  };

  factory AnchorItem.fromJson(Map<String, dynamic> json) => AnchorItem(
    name: json['name'] as String,
    store: json['store'] as String,
    isPantry: json['pantry'] as bool? ?? false,
    // `carb: true` is how a carb was saved before roles replaced it.
    role: AnchorRole.fromName(json['role'] as String?) ?? (json['carb'] == true ? AnchorRole.carb : null),
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
