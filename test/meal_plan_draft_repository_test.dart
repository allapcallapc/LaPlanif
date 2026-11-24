import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_full.dart';
import 'package:laplanif/models/meal_plan_preview.dart';
import 'package:laplanif/services/meal_plan_draft_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const config = MealPlanConfig(
    portionsPerMeal: 3,
    diversityWindowDays: 28,
    mealSlots: [MealSlot(id: 'slot-1', mealType: MealType.lunch, protein: 'meat', count: 2)],
    dietaryNotes: 'no red meat',
  );

  const preview = MealPlanPreview(
    slots: [
      MealSlotPreview(
        mealType: MealType.lunch,
        protein: 'meat',
        count: 2,
        portionsPerMeal: 3,
        anchorItems: [AnchorItem(name: 'Poulet', store: 'IGA')],
        note: 'Roast chicken with vegetables',
      ),
    ],
  );

  const fullSlot = MealSlotFull(
    mealType: MealType.lunch,
    protein: 'meat',
    count: 2,
    portionsPerMeal: 3,
    proteinComponent: MealComponent(
      type: MealComponentType.aiRecipe,
      name: 'Roast chicken',
      ingredients: [Ingredient(name: 'Poulet', amount: '1 kg')],
      instructions: ['Roast at 400F for 45 minutes.'],
      usesWeeklyDeal: true,
      dealItems: [AnchorItem(name: 'Poulet', store: 'IGA')],
    ),
    carbComponent: MealComponent(type: MealComponentType.simpleSide, name: 'Rice', usesWeeklyDeal: false),
    vegetableComponent: MealComponent(type: MealComponentType.simpleSide, name: 'Carrots', usesWeeklyDeal: false),
  );

  test('load returns null when nothing was ever saved', () async {
    final repo = MealPlanDraftRepository();

    expect(await repo.load(), isNull);
  });

  test('save then load round-trips the config, preview and per-slot recipes, including ungenerated slots', () async {
    final repo = MealPlanDraftRepository();
    const draft = MealPlanDraft(config: config, preview: preview, slotRecipes: [null]);

    await repo.save(draft);
    final loaded = await repo.load();

    expect(loaded, isNotNull);
    expect(loaded!.config.dietaryNotes, 'no red meat');
    expect(loaded.config.mealSlots.single.protein, 'meat');
    expect(loaded.preview.slots.single.note, 'Roast chicken with vegetables');
    expect(loaded.preview.slots.single.anchorItems.single.name, 'Poulet');
    expect(loaded.slotRecipes, [null]);
  });

  test('round-trips which step the draft was left on', () async {
    final repo = MealPlanDraftRepository();

    await repo.save(const MealPlanDraft(config: config, preview: preview, slotRecipes: [null]));
    expect((await repo.load())!.ingredientsConfirmed, isFalse);

    await repo.save(
      const MealPlanDraft(config: config, preview: preview, slotRecipes: [null], ingredientsConfirmed: true),
    );
    expect((await repo.load())!.ingredientsConfirmed, isTrue);
  });

  test('a draft saved before the ingredients step existed resumes on recipes only once safe to', () {
    Map<String, dynamic> legacy(MealPlanPreview preview, List<MealSlotFull?> recipes) =>
        MealPlanDraft(config: config, preview: preview, slotRecipes: recipes).toJson()..remove('ingredientsConfirmed');
    final withCarb = MealPlanPreview(
      slots: [preview.slots.single.copyWith(anchorItems: [...preview.slots.single.anchorItems, const AnchorItem.pantry('Riz')])],
    );

    // A recipe exists and every meal has its carb: on recipes.
    expect(MealPlanDraft.fromJson(legacy(withCarb, const [fullSlot])).ingredientsConfirmed, isTrue);
    // No recipe yet: on ingredients.
    expect(MealPlanDraft.fromJson(legacy(withCarb, const [null])).ingredientsConfirmed, isFalse);
    // A recipe exists, but the meal never had a carb marked (as in every
    // draft from before carbs were tracked): back on ingredients, where a
    // carb is required.
    expect(MealPlanDraft.fromJson(legacy(preview, const [fullSlot])).ingredientsConfirmed, isFalse);
  });

  test('round-trips an already-generated slot recipe', () async {
    final repo = MealPlanDraftRepository();
    const draft = MealPlanDraft(config: config, preview: preview, slotRecipes: [fullSlot]);

    await repo.save(draft);
    final loaded = await repo.load();

    expect(loaded!.slotRecipes.single!.recipeName, 'Roast chicken');
    expect(loaded.slotRecipes.single!.proteinComponent.ingredients.single.name, 'Poulet');
  });

  test('clear removes the saved draft', () async {
    final repo = MealPlanDraftRepository();
    await repo.save(const MealPlanDraft(config: config, preview: preview, slotRecipes: [null]));

    await repo.clear();

    expect(await repo.load(), isNull);
  });

  test('returns null when stored data is from an incompatible old schema', () async {
    SharedPreferences.setMockInitialValues({'meal_plan_draft': '{"not":"a draft"}'});

    final repo = MealPlanDraftRepository();

    expect(await repo.load(), isNull);
  });
}
