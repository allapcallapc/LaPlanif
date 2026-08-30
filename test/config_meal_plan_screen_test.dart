import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/screens/config_meal_plan_screen.dart';
import 'package:laplanif/services/meal_plan_config_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(WidgetTester tester, MealPlanConfigRepository repo) async {
    await tester.pumpWidget(MaterialApp(home: ConfigMealPlanScreen(repository: repo)));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the default meal plan config and computed meals per week', (tester) async {
    final repo = MealPlanConfigRepository();
    await pumpScreen(tester, repo);

    expect(find.widgetWithText(TextField, 'Portions per meal'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('28'), findsOneWidget);
    expect(find.text('11 meals / week'), findsOneWidget);
  });

  testWidgets('adding a meal slot appends a default row and updates the weekly total', (tester) async {
    final repo = MealPlanConfigRepository();
    await pumpScreen(tester, repo);

    await tester.tap(find.byTooltip('Add meal slot'));
    await tester.pumpAndSettle();
    // The persistence write is debounced; advance past the debounce window.
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('12 meals / week'), findsOneWidget);
    final saved = await repo.load();
    expect(saved.mealSlots.length, 4);
    expect(saved.mealsPerWeek, 12);
  });

  testWidgets('removing a meal slot deletes it and persists', (tester) async {
    final repo = MealPlanConfigRepository();
    await pumpScreen(tester, repo);

    await tester.tap(find.byTooltip('Remove meal slot').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    // The persistence write is debounced; advance past the debounce window.
    await tester.pump(const Duration(milliseconds: 600));

    final saved = await repo.load();
    expect(saved.mealSlots.length, 2);
    expect(saved.mealsPerWeek, 6);
  });

  testWidgets('editing the count field persists the new value and total', (tester) async {
    final repo = MealPlanConfigRepository();
    await pumpScreen(tester, repo);

    await tester.enterText(find.widgetWithText(TextFormField, 'Count').first, '7');
    await tester.pumpAndSettle();
    // The persistence write is debounced; advance past the debounce window.
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('13 meals / week'), findsOneWidget);
    final saved = await repo.load();
    expect(saved.mealSlots.first.count, 7);
  });

  testWidgets('editing portions per meal persists the new value', (tester) async {
    final repo = MealPlanConfigRepository();
    await pumpScreen(tester, repo);

    await tester.enterText(find.widgetWithText(TextField, 'Portions per meal'), '5');
    await tester.pumpAndSettle();
    // The persistence write is debounced; advance past the debounce window.
    await tester.pump(const Duration(milliseconds: 600));

    final saved = await repo.load();
    expect(saved.portionsPerMeal, 5);
  });

  testWidgets('editing the diversity window persists the new value', (tester) async {
    final repo = MealPlanConfigRepository();
    await pumpScreen(tester, repo);

    await tester.enterText(find.widgetWithText(TextField, 'Diversity window (days)'), '21');
    await tester.pumpAndSettle();
    // The persistence write is debounced; advance past the debounce window.
    await tester.pump(const Duration(milliseconds: 600));

    final saved = await repo.load();
    expect(saved.diversityWindowDays, 21);
  });

  testWidgets('editing the additional planning instructions persists the new value', (tester) async {
    final repo = MealPlanConfigRepository();
    await pumpScreen(tester, repo);

    await tester.enterText(find.widgetWithText(TextField, 'Additional planning instructions'), 'No shellfish.');
    await tester.pumpAndSettle();
    // The persistence write is debounced; advance past the debounce window.
    await tester.pump(const Duration(milliseconds: 600));

    final saved = await repo.load();
    expect(saved.dietaryNotes, 'No shellfish.');
  });

  testWidgets('editing the protein field persists the new value', (tester) async {
    final repo = MealPlanConfigRepository();
    await pumpScreen(tester, repo);

    await tester.enterText(find.byKey(const ValueKey('protein-default-lunch-meat')), 'fish');
    await tester.pumpAndSettle();
    // The persistence write is debounced; advance past the debounce window.
    await tester.pump(const Duration(milliseconds: 600));

    final saved = await repo.load();
    expect(saved.mealSlots.first.protein, 'fish');
  });

  testWidgets('changing the meal type dropdown persists the new value', (tester) async {
    final repo = MealPlanConfigRepository();
    await pumpScreen(tester, repo);

    final dropdown = tester.widget<DropdownButtonFormField<MealType>>(
      find.byKey(const ValueKey('meal-type-default-lunch-meat')),
    );
    dropdown.onChanged!(MealType.supper);
    await tester.pumpAndSettle();
    // The persistence write is debounced; advance past the debounce window.
    await tester.pump(const Duration(milliseconds: 600));

    final saved = await repo.load();
    expect(saved.mealSlots.first.mealType, MealType.supper);
  });

  testWidgets('flushes a pending meal plan save when disposed before the debounce fires', (tester) async {
    final repo = MealPlanConfigRepository();
    await pumpScreen(tester, repo);

    await tester.enterText(find.widgetWithText(TextField, 'Portions per meal'), '6');
    // Still inside the debounce window - nothing written yet.
    await tester.pump(const Duration(milliseconds: 100));
    expect((await repo.load()).portionsPerMeal, 3);

    // Navigate away before the debounce fires, disposing the screen.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    // The pending save was flushed rather than dropped.
    expect((await repo.load()).portionsPerMeal, 6);
  });

  testWidgets('removing a meal slot does not leave stale text in the row that shifts into its place', (
    tester,
  ) async {
    final repo = MealPlanConfigRepository();
    await pumpScreen(tester, repo);

    // Default seed is [lunch/meat/5, supper/meat/2, supper/tofu/4]. Remove
    // the first row so supper/meat/2 shifts into index 0. If rows were keyed
    // by list position, Flutter would reuse the removed row's Element/State
    // and the Count field would keep showing '5' instead of '2'.
    await tester.tap(find.byTooltip('Remove meal slot').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));

    final editable = tester.widget<EditableText>(
      find.descendant(of: find.widgetWithText(TextFormField, 'Count').first, matching: find.byType(EditableText)),
    );
    expect(editable.controller.text, '2');
  });
}
