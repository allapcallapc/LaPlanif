import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/meal_plan_config.dart';

class MealPlanConfigRepository {
  static const _prefsKey = 'meal_plan_config';

  static MealPlanConfig defaultConfig() => const MealPlanConfig(
    portionsPerMeal: 3,
    diversityWindowDays: 28,
    mealSlots: [
      MealSlot(id: 'default-lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5),
      MealSlot(id: 'default-supper-meat', mealType: MealType.supper, protein: 'meat', count: 2),
      MealSlot(id: 'default-supper-tofu', mealType: MealType.supper, protein: 'tofu', count: 4),
    ],
    dietaryNotes:
        '- No more than 2 days of fish per week.\n'
        '- Prefer lunches that can be frozen.\n'
        '- No red meat.',
  );

  Future<MealPlanConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        return MealPlanConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        // Leftover data from an older, incompatible schema - reseed below.
      }
    }
    final defaults = defaultConfig();
    await save(defaults);
    return defaults;
  }

  Future<void> save(MealPlanConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(config.toJson()));
  }
}
