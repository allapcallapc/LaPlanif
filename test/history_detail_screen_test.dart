import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/meal_history.dart';
import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_full.dart';
import 'package:laplanif/models/meal_plan_preview.dart';
import 'package:laplanif/screens/history_detail_screen.dart';
import 'package:laplanif/services/meal_history_repository.dart';

MealHistoryEntry _entry() => MealHistoryEntry(
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
        usesWeeklyDeal: true,
        dealItems: [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
      ),
      carbComponent: MealComponent(type: MealComponentType.simpleSide, name: 'Rice', usesWeeklyDeal: false),
      vegetableComponent: MealComponent(type: MealComponentType.simpleSide, name: 'Broccoli', usesWeeklyDeal: false),
    ),
  ],
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows the saved slot using the shared full-plan card', (tester) async {
    final repository = MealHistoryRepository();
    await repository.saveWeek(_entry());

    await tester.pumpWidget(
      MaterialApp(home: HistoryDetailScreen(entry: _entry(), repository: repository)),
    );
    await tester.pumpAndSettle();

    expect(find.text('2026-W34'), findsOneWidget);
    expect(find.text('General Tao Chicken'), findsOneWidget);
    expect(find.text('Chicken thighs · IGA'), findsOneWidget);
  });

  testWidgets('editing a slot recipe name and saving overwrites the week in the repository', (tester) async {
    final repository = MealHistoryRepository();
    await repository.saveWeek(_entry());

    await tester.pumpWidget(
      MaterialApp(home: HistoryDetailScreen(entry: _entry(), repository: repository)),
    );
    await tester.pumpAndSettle();

    // No unsaved-changes bar until an edit is made.
    expect(find.text('Save changes'), findsNothing);

    await tester.tap(find.byTooltip('Edit this slot'));
    await tester.pumpAndSettle();

    final nameField = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'General Tao Chicken');
    expect(nameField, findsOneWidget);
    await tester.enterText(nameField, 'Honey Garlic Chicken');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('Save changes'), findsOneWidget);
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    final saved = await repository.loadAll();
    expect(saved.single.slots.single.recipeName, 'Honey Garlic Chicken');
  });

  testWidgets('falls back to a default repository when none is provided', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HistoryDetailScreen(entry: _entry())));
    await tester.pumpAndSettle();

    expect(find.text('2026-W34'), findsOneWidget);
    expect(find.text('General Tao Chicken'), findsOneWidget);
  });

  testWidgets('adds, edits and removes an anchor item from within the edit-slot dialog', (tester) async {
    final repository = MealHistoryRepository();
    await repository.saveWeek(_entry());

    await tester.pumpWidget(
      MaterialApp(home: HistoryDetailScreen(entry: _entry(), repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit this slot'));
    await tester.pumpAndSettle();

    // The vegetable component starts with no anchors, so its "Add anchor"
    // chip is the second of the three sections' chips.
    await tester.tap(find.text('Add anchor').at(2));
    await tester.pumpAndSettle();

    expect(find.text('Add anchor item'), findsOneWidget);

    // Saving with an empty name is a no-op - the dialog stays open.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Add anchor item'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Item name'), 'Broccoli');
    await tester.enterText(find.widgetWithText(TextField, 'Store'), 'IGA');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Broccoli · IGA'), findsOneWidget);

    // Editing the newly-added anchor: Cancel leaves it unchanged.
    await tester.tap(find.text('Broccoli · IGA'));
    await tester.pumpAndSettle();
    expect(find.text('Edit anchor item'), findsOneWidget);
    // Two "Cancel" buttons are in the tree at once - the edit-slot dialog's
    // own Cancel sits behind this anchor dialog - so target the topmost one.
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.text('Broccoli · IGA'), findsOneWidget);

    // Editing again and saving updates the chip.
    await tester.tap(find.text('Broccoli · IGA'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Item name'), 'Carrots');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Carrots · IGA'), findsOneWidget);
    expect(find.text('Broccoli · IGA'), findsNothing);

    // Removing it via the chip's delete icon.
    final chip = find.ancestor(of: find.text('Carrots · IGA'), matching: find.byType(InputChip));
    await tester.tap(find.descendant(of: chip, matching: find.byIcon(Icons.close)));
    await tester.pumpAndSettle();

    expect(find.text('Carrots · IGA'), findsNothing);
  });

  testWidgets('deleting a week removes it from the repository and pops', (tester) async {
    final repository = MealHistoryRepository();
    await repository.saveWeek(_entry());

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => HistoryDetailScreen(entry: _entry(), repository: repository)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete this week'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(await repository.loadAll(), isEmpty);
  });
}
