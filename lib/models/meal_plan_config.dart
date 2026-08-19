enum MealType {
  lunch,
  supper;

  static MealType fromName(String name) => MealType.values.firstWhere((t) => t.name == name);
}

/// One row of the meal plan: how many meals of a given type/protein
/// combination to plan per week. Protein is a free-form string rather than
/// an enum so new protein types (fish, vegetarian-other, ...) can be added
/// from the config screen without a code change.
class MealSlot {
  // A stable identity separate from list position, so the config screen can
  // key each row's fields on it - keying by index instead makes Flutter
  // reuse a text field's Element/State for whichever row now sits at that
  // index after a row above it is removed, leaving stale text on screen.
  const MealSlot({required this.id, required this.mealType, required this.protein, required this.count});

  final String id;
  final MealType mealType;
  final String protein;
  final int count;

  MealSlot copyWith({MealType? mealType, String? protein, int? count}) => MealSlot(
    id: id,
    mealType: mealType ?? this.mealType,
    protein: protein ?? this.protein,
    count: count ?? this.count,
  );

  Map<String, dynamic> toJson() => {'id': id, 'mealType': mealType.name, 'protein': protein, 'count': count};

  factory MealSlot.fromJson(Map<String, dynamic> json) => MealSlot(
    id: json['id'] as String,
    mealType: MealType.fromName(json['mealType'] as String),
    protein: json['protein'] as String,
    count: json['count'] as int,
  );
}

class MealPlanConfig {
  const MealPlanConfig({required this.portionsPerMeal, required this.diversityWindowDays, required this.mealSlots});

  final int portionsPerMeal;
  final int diversityWindowDays;
  final List<MealSlot> mealSlots;

  /// Total planned meals per week, derived from the slot counts rather than
  /// stored separately so it can never drift out of sync with them.
  int get mealsPerWeek => mealSlots.fold(0, (sum, slot) => sum + slot.count);

  MealPlanConfig copyWith({int? portionsPerMeal, int? diversityWindowDays, List<MealSlot>? mealSlots}) =>
      MealPlanConfig(
        portionsPerMeal: portionsPerMeal ?? this.portionsPerMeal,
        diversityWindowDays: diversityWindowDays ?? this.diversityWindowDays,
        mealSlots: mealSlots ?? this.mealSlots,
      );

  Map<String, dynamic> toJson() => {
    'portionsPerMeal': portionsPerMeal,
    'diversityWindowDays': diversityWindowDays,
    'mealSlots': mealSlots.map((s) => s.toJson()).toList(),
  };

  factory MealPlanConfig.fromJson(Map<String, dynamic> json) => MealPlanConfig(
    portionsPerMeal: json['portionsPerMeal'] as int,
    diversityWindowDays: json['diversityWindowDays'] as int,
    mealSlots: (json['mealSlots'] as List<dynamic>)
        .map((e) => MealSlot.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}
