import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/models/meal_history.dart';
import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_full.dart';
import 'package:laplanif/models/meal_plan_preview.dart';

void main() {
  const protein = MealComponent(
    type: MealComponentType.link,
    name: 'General Tao Chicken',
    recipeUrl: 'https://example.com/general-tao',
    usesWeeklyDeal: true,
    dealItems: [AnchorItem(name: 'chicken thighs', store: 'IGA')],
  );
  const carb = MealComponent(type: MealComponentType.coveredByProtein, name: 'Rice', usesWeeklyDeal: false);
  const vegetable = MealComponent(
    type: MealComponentType.simpleSide,
    name: 'Steamed broccoli',
    note: 'Steam 5 min.',
    usesWeeklyDeal: true,
    dealItems: [AnchorItem(name: 'Broccoli', store: 'IGA')],
  );
  const slot = MealSlotFull(
    mealType: MealType.lunch,
    protein: 'meat',
    count: 5,
    portionsPerMeal: 3,
    proteinComponent: protein,
    carbComponent: carb,
    vegetableComponent: vegetable,
  );

  test('MealSlotFull.recipeName is the protein component name', () {
    expect(slot.recipeName, 'General Tao Chicken');
  });

  test('MealSlotFull.dealItemsUsed collects deal items across components, deduped by name+store', () {
    const duplicateVegetable = MealComponent(
      type: MealComponentType.simpleSide,
      name: 'Steamed broccoli',
      usesWeeklyDeal: true,
      dealItems: [AnchorItem(name: 'Chicken thighs', store: 'iga')],
    );
    final withDuplicate = slot.copyWith(vegetableComponent: duplicateVegetable);

    expect(withDuplicate.dealItemsUsed.map((a) => a.name), ['chicken thighs']);
  });

  test('MealSlotFull.dealItemsUsed skips components not marked usesWeeklyDeal', () {
    expect(slot.dealItemsUsed.map((a) => a.name), ['chicken thighs', 'Broccoli']);
  });

  test('MealSlotFull round-trips through JSON', () {
    final json = slot.toJson();
    final restored = MealSlotFull.fromJson(json);

    expect(restored.mealType, slot.mealType);
    expect(restored.protein, slot.protein);
    expect(restored.count, slot.count);
    expect(restored.portionsPerMeal, slot.portionsPerMeal);
    expect(restored.proteinComponent.name, slot.proteinComponent.name);
    expect(restored.proteinComponent.recipeUrl, slot.proteinComponent.recipeUrl);
    expect(restored.proteinComponent.dealItems.single.name, 'chicken thighs');
    expect(restored.carbComponent.type, MealComponentType.coveredByProtein);
    expect(restored.vegetableComponent.note, 'Steam 5 min.');
  });

  test('MealHistoryEntry round-trips through JSON', () {
    final entry = MealHistoryEntry(weekId: '2026-W34', savedAt: DateTime.utc(2026, 8, 20, 14, 32), slots: [slot]);

    final restored = MealHistoryEntry.fromJson(entry.toJson());

    expect(restored.weekId, '2026-W34');
    expect(restored.savedAt, DateTime.utc(2026, 8, 20, 14, 32));
    expect(restored.slots.single.recipeName, 'General Tao Chicken');
  });

  test('MealHistoryEntry.copyWith overwrites only the given fields', () {
    final entry = MealHistoryEntry(weekId: '2026-W34', savedAt: DateTime.utc(2026, 8, 20), slots: [slot]);

    final updated = entry.copyWith(savedAt: DateTime.utc(2026, 8, 21));

    expect(updated.weekId, '2026-W34');
    expect(updated.savedAt, DateTime.utc(2026, 8, 21));
    expect(updated.slots, [slot]);
  });
}
