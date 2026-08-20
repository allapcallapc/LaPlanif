import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_preview.dart';

void main() {
  test('AnchorItem exposes the fields it was constructed with', () {
    final anchor = AnchorItem(name: 'Chicken thighs', store: 'IGA');

    expect(anchor.name, 'Chicken thighs');
    expect(anchor.store, 'IGA');
  });

  test('AnchorItem round-trips through JSON', () {
    final anchor = AnchorItem(name: 'Chicken thighs', store: 'IGA');

    final restored = AnchorItem.fromJson(anchor.toJson());

    expect(restored.name, 'Chicken thighs');
    expect(restored.store, 'IGA');
  });

  test('MealSlotPreview exposes the fields it was constructed with', () {
    final slot = MealSlotPreview(
      mealType: MealType.lunch,
      protein: 'meat',
      count: 5,
      portionsPerMeal: 3,
      anchorItems: [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
      note: 'Big-batch chicken thigh stir-fry.',
    );

    expect(slot.mealType, MealType.lunch);
    expect(slot.protein, 'meat');
    expect(slot.count, 5);
    expect(slot.portionsPerMeal, 3);
    expect(slot.anchorItems.single.name, 'Chicken thighs');
    expect(slot.note, 'Big-batch chicken thigh stir-fry.');
  });

  test('totalPortionsNeeded multiplies count by portionsPerMeal', () {
    final slot = MealSlotPreview(
      mealType: MealType.supper,
      protein: 'tofu',
      count: 4,
      portionsPerMeal: 3,
      anchorItems: const [],
      note: 'note',
    );

    expect(slot.totalPortionsNeeded, 12);
  });

  test('copyWith replaces anchorItems and keeps other fields', () {
    final original = MealSlotPreview(
      mealType: MealType.lunch,
      protein: 'meat',
      count: 5,
      portionsPerMeal: 3,
      anchorItems: [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
      note: 'Big-batch chicken thigh stir-fry.',
    );

    final updated = original.copyWith(anchorItems: [AnchorItem(name: 'Ground pork', store: 'IGA')]);

    expect(updated.anchorItems.single.name, 'Ground pork');
    expect(updated.mealType, original.mealType);
    expect(updated.protein, original.protein);
    expect(updated.count, original.count);
    expect(updated.portionsPerMeal, original.portionsPerMeal);
    expect(updated.note, original.note);
    expect(original.anchorItems.single.name, 'Chicken thighs', reason: 'original slot is unchanged');
  });

  test('copyWith with no anchorItems argument keeps the existing anchor items', () {
    final original = MealSlotPreview(
      mealType: MealType.lunch,
      protein: 'meat',
      count: 5,
      portionsPerMeal: 3,
      anchorItems: [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
      note: 'note',
    );

    final updated = original.copyWith();

    expect(updated.anchorItems.single.name, 'Chicken thighs');
  });

  test('MealPlanPreview exposes the slots it was constructed with', () {
    final slot = MealSlotPreview(
      mealType: MealType.lunch,
      protein: 'meat',
      count: 5,
      portionsPerMeal: 3,
      anchorItems: const [],
      note: 'note',
    );
    final preview = MealPlanPreview(slots: [slot]);

    expect(preview.slots, [slot]);
  });
}
