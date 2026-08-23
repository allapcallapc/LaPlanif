import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_full.dart';
import 'package:laplanif/widgets/ingredient_list_dialog.dart';

void main() {
  const slot = MealSlotFull(
    mealType: MealType.lunch,
    protein: 'meat',
    count: 1,
    portionsPerMeal: 1,
    proteinComponent: MealComponent(
      type: MealComponentType.aiRecipe,
      name: 'Chicken stir-fry',
      ingredients: [Ingredient(name: 'Chicken thighs', amount: '1.5 kg')],
      usesWeeklyDeal: false,
    ),
    carbComponent: MealComponent(type: MealComponentType.coveredByProtein, name: 'Rice', usesWeeklyDeal: false),
    vegetableComponent: MealComponent(type: MealComponentType.simpleSide, name: 'Broccoli', usesWeeklyDeal: false),
  );

  Future<void> pumpAndOpen(WidgetTester tester, List<MealSlotFull> slots) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showIngredientListDialog(context, slots),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists every extracted ingredient, skipping the covered-by-protein component', (tester) async {
    await pumpAndOpen(tester, [slot]);

    expect(find.text('Chicken thighs — 1.5 kg'), findsOneWidget);
    expect(find.text('Broccoli'), findsOneWidget);
    expect(find.text('Rice'), findsNothing);
  });

  testWidgets('shows a fallback message when the plan has no ingredients', (tester) async {
    const emptySlot = MealSlotFull(
      mealType: MealType.lunch,
      protein: 'meat',
      count: 1,
      portionsPerMeal: 1,
      proteinComponent: MealComponent(type: MealComponentType.coveredByProtein, name: 'a', usesWeeklyDeal: false),
      carbComponent: MealComponent(type: MealComponentType.coveredByProtein, name: 'b', usesWeeklyDeal: false),
      vegetableComponent: MealComponent(type: MealComponentType.coveredByProtein, name: 'c', usesWeeklyDeal: false),
    );

    await pumpAndOpen(tester, [emptySlot]);

    expect(find.text('No ingredients to list.'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Copy'), findsNothing);
  });

  testWidgets('copies the plain-text ingredient list to the clipboard', (tester) async {
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpAndOpen(tester, [slot]);
    await tester.tap(find.widgetWithText(TextButton, 'Copy'));
    await tester.pumpAndSettle();

    expect(copied.single, '- Broccoli\n- Chicken thighs — 1.5 kg');
    expect(find.text('Ingredient list copied to clipboard.'), findsOneWidget);
  });
}
