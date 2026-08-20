import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_full.dart';
import 'package:laplanif/models/meal_plan_preview.dart';

void main() {
  test('MealComponentType round-trips through its wire value', () {
    for (final type in MealComponentType.values) {
      expect(MealComponentType.fromValue(type.value), type);
    }
  });

  test('MealComponentType.fromValue throws on an unknown value', () {
    expect(() => MealComponentType.fromValue('not_a_type'), throwsArgumentError);
  });

  test('Ingredient exposes the fields it was constructed with', () {
    const ingredient = Ingredient(name: 'chicken thighs', amount: '1.5 kg');

    expect(ingredient.name, 'chicken thighs');
    expect(ingredient.amount, '1.5 kg');
  });

  test('MealComponent exposes the fields it was constructed with, including defaults', () {
    const component = MealComponent(type: MealComponentType.simpleSide, name: 'Steamed broccoli', usesWeeklyDeal: false);

    expect(component.type, MealComponentType.simpleSide);
    expect(component.name, 'Steamed broccoli');
    expect(component.recipeUrl, isNull);
    expect(component.ingredients, isEmpty);
    expect(component.instructions, isEmpty);
    expect(component.note, '');
    expect(component.usesWeeklyDeal, isFalse);
    expect(component.dealItems, isEmpty);
  });

  test('MealComponent carries a link, ingredients, instructions and deal items', () {
    const component = MealComponent(
      type: MealComponentType.aiRecipe,
      name: 'Big-batch chicken thigh stir-fry',
      ingredients: [Ingredient(name: 'chicken thighs', amount: '1.5 kg')],
      instructions: ['Sear the chicken.', 'Add the vegetables.'],
      usesWeeklyDeal: true,
      dealItems: [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
    );

    expect(component.ingredients.single.name, 'chicken thighs');
    expect(component.instructions, ['Sear the chicken.', 'Add the vegetables.']);
    expect(component.usesWeeklyDeal, isTrue);
    expect(component.dealItems.single.name, 'Chicken thighs');
  });

  test('MealSlotFull totalPortionsNeeded multiplies count by portionsPerMeal', () {
    const protein = MealComponent(type: MealComponentType.link, name: 'Chicken stir-fry', usesWeeklyDeal: true);
    const carb = MealComponent(type: MealComponentType.coveredByProtein, name: 'Rice', usesWeeklyDeal: false);
    const vegetable = MealComponent(type: MealComponentType.simpleSide, name: 'Broccoli', usesWeeklyDeal: false);

    const slot = MealSlotFull(
      mealType: MealType.lunch,
      protein: 'meat',
      count: 5,
      portionsPerMeal: 3,
      proteinComponent: protein,
      carbComponent: carb,
      vegetableComponent: vegetable,
    );

    expect(slot.totalPortionsNeeded, 15);
    expect(slot.proteinComponent, protein);
    expect(slot.carbComponent, carb);
    expect(slot.vegetableComponent, vegetable);
  });

  test('MealPlanFull exposes the slots it was constructed with', () {
    const protein = MealComponent(type: MealComponentType.link, name: 'Chicken stir-fry', usesWeeklyDeal: true);
    const carb = MealComponent(type: MealComponentType.coveredByProtein, name: 'Rice', usesWeeklyDeal: false);
    const vegetable = MealComponent(type: MealComponentType.simpleSide, name: 'Broccoli', usesWeeklyDeal: false);
    const slot = MealSlotFull(
      mealType: MealType.lunch,
      protein: 'meat',
      count: 5,
      portionsPerMeal: 3,
      proteinComponent: protein,
      carbComponent: carb,
      vegetableComponent: vegetable,
    );

    const plan = MealPlanFull(slots: [slot]);

    expect(plan.slots, [slot]);
  });
}
