import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/services/meal_plan_config_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('seeds the default portions, diversity window and meal slots on first load', () async {
    final repo = MealPlanConfigRepository();
    final config = await repo.load();

    expect(config.portionsPerMeal, 3);
    expect(config.diversityWindowDays, 28);
    expect(config.mealSlots.map((s) => (s.mealType, s.protein, s.count)), [
      (MealType.lunch, 'meat', 5),
      (MealType.supper, 'meat', 2),
      (MealType.supper, 'tofu', 4),
    ]);
    expect(config.dietaryNotes, contains('No more than 2 days of fish per week'));
    expect(config.dietaryNotes, contains('Prefer lunches that can be frozen'));
    expect(config.dietaryNotes, contains('No red meat'));
  });

  test('mealsPerWeek is the sum of the slot counts', () async {
    final repo = MealPlanConfigRepository();
    final config = await repo.load();

    expect(config.mealsPerWeek, 11);
  });

  test('reseeds defaults when stored data is from an incompatible old schema', () async {
    SharedPreferences.setMockInitialValues({'meal_plan_config': '{"mealsPerWeek": 14}'});

    final repo = MealPlanConfigRepository();
    final config = await repo.load();

    expect(config.portionsPerMeal, 3);
    expect(config.mealSlots.length, 3);
  });

  test('defaults dietaryNotes to empty when loading a config saved before the field existed', () async {
    SharedPreferences.setMockInitialValues({
      'meal_plan_config': jsonEncode({
        'portionsPerMeal': 3,
        'diversityWindowDays': 28,
        'mealSlots': [
          {'id': 'a', 'mealType': 'lunch', 'protein': 'meat', 'count': 1},
        ],
      }),
    });

    final repo = MealPlanConfigRepository();
    final config = await repo.load();

    expect(config.dietaryNotes, '');
  });

  test('persists changes between loads', () async {
    final repo = MealPlanConfigRepository();
    final config = await repo.load();

    final updated = config.copyWith(
      portionsPerMeal: 4,
      diversityWindowDays: 21,
      mealSlots: [
        ...config.mealSlots,
        const MealSlot(id: 'extra-fish', mealType: MealType.lunch, protein: 'fish', count: 1),
      ],
      dietaryNotes: 'No shellfish.',
    );
    await repo.save(updated);

    final reloaded = await repo.load();
    expect(reloaded.portionsPerMeal, 4);
    expect(reloaded.diversityWindowDays, 21);
    expect(reloaded.mealSlots.map((s) => s.protein), contains('fish'));
    expect(reloaded.mealsPerWeek, 12);
    expect(reloaded.dietaryNotes, 'No shellfish.');
  });
}
