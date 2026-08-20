import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/meal_history.dart';
import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_full.dart';
import 'package:laplanif/screens/history_screen.dart';
import 'package:laplanif/services/meal_history_repository.dart';

MealSlotFull _slot(String recipeName) => MealSlotFull(
  mealType: MealType.lunch,
  protein: 'meat',
  count: 5,
  portionsPerMeal: 3,
  proteinComponent: MealComponent(type: MealComponentType.link, name: recipeName, usesWeeklyDeal: false),
  carbComponent: const MealComponent(type: MealComponentType.simpleSide, name: 'Rice', usesWeeklyDeal: false),
  vegetableComponent: const MealComponent(type: MealComponentType.simpleSide, name: 'Broccoli', usesWeeklyDeal: false),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows an empty state when nothing has been saved yet', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HistoryScreen(repository: MealHistoryRepository())));
    await tester.pumpAndSettle();

    expect(find.textContaining('No saved weeks yet'), findsOneWidget);
  });

  testWidgets('lists saved weeks most recent first', (tester) async {
    final repository = MealHistoryRepository();
    await repository.saveWeek(
      MealHistoryEntry(weekId: '2026-W20', savedAt: DateTime.utc(2026, 5, 14), slots: [_slot('Old recipe')]),
    );
    await repository.saveWeek(
      MealHistoryEntry(weekId: '2026-W34', savedAt: DateTime.utc(2026, 8, 20), slots: [_slot('New recipe')]),
    );

    await tester.pumpWidget(MaterialApp(home: HistoryScreen(repository: repository)));
    await tester.pumpAndSettle();

    final weekIdFinder = find.byWidgetPredicate((w) => w is Text && (w.data == '2026-W34' || w.data == '2026-W20'));
    expect(weekIdFinder, findsNWidgets(2));

    final tiles = tester.widgetList<Text>(weekIdFinder).map((t) => t.data).toList();
    expect(tiles, ['2026-W34', '2026-W20']);
  });

  testWidgets('opens a week into the detail screen on tap', (tester) async {
    final repository = MealHistoryRepository();
    await repository.saveWeek(
      MealHistoryEntry(weekId: '2026-W34', savedAt: DateTime.utc(2026, 8, 20), slots: [_slot('General Tao Chicken')]),
    );

    await tester.pumpWidget(MaterialApp(home: HistoryScreen(repository: repository)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('2026-W34'));
    await tester.pumpAndSettle();

    expect(find.text('General Tao Chicken'), findsOneWidget);
  });

  testWidgets('reloads the list once the detail screen is popped, reflecting a deletion made there', (tester) async {
    final repository = MealHistoryRepository();
    await repository.saveWeek(
      MealHistoryEntry(weekId: '2026-W34', savedAt: DateTime.utc(2026, 8, 20), slots: [_slot('General Tao Chicken')]),
    );

    await tester.pumpWidget(MaterialApp(home: HistoryScreen(repository: repository)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('2026-W34'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete this week'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No saved weeks yet'), findsOneWidget);
  });
}
