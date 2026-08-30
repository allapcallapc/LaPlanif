import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/main.dart';
import 'package:laplanif/models/meal_history.dart';
import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_full.dart';
import 'package:laplanif/services/meal_history_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows the Planif and Config tabs', (WidgetTester tester) async {
    await tester.pumpWidget(const LaPlanifApp());
    await tester.pumpAndSettle();

    expect(find.text('Planif'), findsWidgets);
    expect(find.text('Config'), findsWidgets);
  });

  // Both the nav label and each screen's own AppBar title can read the same
  // text ("Config"/"Planif"), and find.text() skips offstage IndexedStack
  // branches by default, so tab switches in these tests go through the
  // NavigationBar specifically rather than a bare find.text(label).
  Finder navDestination(String label) =>
      find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

  testWidgets('default store list is preconfigured', (WidgetTester tester) async {
    await tester.pumpWidget(const LaPlanifApp());
    await tester.pumpAndSettle();

    await tester.tap(navDestination('Config'));
    await tester.pumpAndSettle();

    // Stores is its own drill-down screen off the Config menu.
    await tester.tap(find.text('Stores'));
    await tester.pumpAndSettle();

    expect(find.text('IGA'), findsOneWidget);
    expect(find.text('Metro'), findsOneWidget);
    expect(find.text('Maxi'), findsOneWidget);
  });

  testWidgets('tapping the Config destination switches tabs', (WidgetTester tester) async {
    await tester.pumpWidget(const LaPlanifApp());
    await tester.pumpAndSettle();

    await tester.tap(navDestination('Config'));
    await tester.pumpAndSettle();

    final stack = tester.widget<IndexedStack>(find.byKey(const Key('home_tab_stack')));
    expect(stack.index, 2);
  });

  testWidgets('shows the History tab and its empty state', (WidgetTester tester) async {
    await tester.pumpWidget(const LaPlanifApp());
    await tester.pumpAndSettle();

    await tester.tap(navDestination('History'));
    await tester.pumpAndSettle();

    final stack = tester.widget<IndexedStack>(find.byKey(const Key('home_tab_stack')));
    expect(stack.index, 1);
    expect(find.textContaining('No saved weeks yet'), findsOneWidget);
  });

  testWidgets('History tab reflects a plan saved after the tab was first built', (WidgetTester tester) async {
    await tester.pumpWidget(const LaPlanifApp());
    await tester.pumpAndSettle();

    // IndexedStack builds every tab up front (that's what lets Planif keep
    // its in-progress state across switches), so History's first load
    // already ran here even though we haven't visited it yet - it just saw
    // nothing saved. Regression coverage for the bug where switching tabs
    // afterwards never re-read the store, so a save made after this point
    // stayed invisible until the app restarted.
    await tester.tap(navDestination('History'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No saved weeks yet'), findsOneWidget);

    // Simulate "Save this week's plan" happening on the Planif tab - some
    // other part of the app writing to the same history store.
    await MealHistoryRepository().saveWeek(
      MealHistoryEntry(
        weekId: '2026-W34',
        savedAt: DateTime.utc(2026, 8, 20),
        slots: [
          const MealSlotFull(
            mealType: MealType.lunch,
            protein: 'meat',
            count: 5,
            portionsPerMeal: 3,
            proteinComponent: MealComponent(
              type: MealComponentType.link,
              name: 'General Tao Chicken',
              usesWeeklyDeal: false,
            ),
            carbComponent: MealComponent(type: MealComponentType.simpleSide, name: 'Rice', usesWeeklyDeal: false),
            vegetableComponent: MealComponent(
              type: MealComponentType.simpleSide,
              name: 'Broccoli',
              usesWeeklyDeal: false,
            ),
          ),
        ],
      ),
    );

    await tester.tap(navDestination('Planif'));
    await tester.pumpAndSettle();
    await tester.tap(navDestination('History'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No saved weeks yet'), findsNothing);
    expect(find.text('2026-W34'), findsOneWidget);
  });
}
