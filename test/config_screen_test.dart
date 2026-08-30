import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/screens/config_ai_screen.dart';
import 'package:laplanif/screens/config_meal_plan_screen.dart';
import 'package:laplanif/screens/config_screen.dart';
import 'package:laplanif/screens/config_stores_screen.dart';
import 'package:laplanif/services/store_config_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: ConfigScreen(repository: StoreConfigRepository())));
    await tester.pumpAndSettle();
  }

  testWidgets('lists Stores, Meal plan, and AI as top-level rows', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Stores'), findsOneWidget);
    expect(find.text('Meal plan'), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
  });

  testWidgets('tapping Stores opens the Stores screen', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Stores'));
    await tester.pumpAndSettle();

    expect(find.byType(ConfigStoresScreen), findsOneWidget);
  });

  testWidgets('tapping Meal plan opens the Meal plan screen', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Meal plan'));
    await tester.pumpAndSettle();

    expect(find.byType(ConfigMealPlanScreen), findsOneWidget);
  });

  testWidgets('tapping AI opens the AI screen', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();

    expect(find.byType(ConfigAiScreen), findsOneWidget);
  });
}
