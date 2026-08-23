import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_full.dart';
import 'package:laplanif/models/meal_plan_preview.dart';
import 'package:laplanif/widgets/meal_slot_full_card.dart';

const _slot = MealSlotFull(
  mealType: MealType.lunch,
  protein: 'meat',
  count: 5,
  portionsPerMeal: 3,
  proteinComponent: MealComponent(
    type: MealComponentType.link,
    name: 'Sheet-pan sausage and veggies',
    recipeUrl: 'https://vertexaisearch.cloud.google.com/grounding-api-redirect/opaque-token',
    recipeSourceTitle: 'Sheet-Pan Sausage and Veggies Recipe',
    usesWeeklyDeal: false,
  ),
  carbComponent: MealComponent(type: MealComponentType.simpleSide, name: 'Rice', note: 'Steamed.', usesWeeklyDeal: false),
  vegetableComponent: MealComponent(
    type: MealComponentType.simpleSide,
    name: 'Broccoli',
    note: 'Steamed.',
    usesWeeklyDeal: false,
  ),
);

void main() {
  testWidgets('shows the grounding source title instead of the raw redirect URL, with the URL in a tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MealSlotFullCard(slot: _slot))));

    expect(find.text('Sheet-Pan Sausage and Veggies Recipe'), findsOneWidget);
    expect(find.text('https://vertexaisearch.cloud.google.com/grounding-api-redirect/opaque-token'), findsNothing);
    expect(
      find.byTooltip('https://vertexaisearch.cloud.google.com/grounding-api-redirect/opaque-token'),
      findsOneWidget,
    );
  });

  testWidgets('falls back to showing the raw URL when grounding returned no title', (tester) async {
    const slot = MealSlotFull(
      mealType: MealType.lunch,
      protein: 'meat',
      count: 5,
      portionsPerMeal: 3,
      proteinComponent: MealComponent(
        type: MealComponentType.link,
        name: 'Untitled recipe',
        recipeUrl: 'https://example.com/untitled-recipe',
        usesWeeklyDeal: false,
      ),
      carbComponent: MealComponent(type: MealComponentType.simpleSide, name: 'Rice', usesWeeklyDeal: false),
      vegetableComponent: MealComponent(type: MealComponentType.simpleSide, name: 'Broccoli', usesWeeklyDeal: false),
    );

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MealSlotFullCard(slot: slot))));

    expect(find.text('https://example.com/untitled-recipe'), findsOneWidget);
  });

  testWidgets('tapping the recipe link launches its recipeUrl, not its display title', (tester) async {
    String? launched;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MealSlotFullCard(slot: _slot, onOpenRecipeLink: (url) => launched = url)),
      ),
    );

    await tester.tap(find.text('Sheet-Pan Sausage and Veggies Recipe'));

    expect(launched, 'https://vertexaisearch.cloud.google.com/grounding-api-redirect/opaque-token');
  });
}
