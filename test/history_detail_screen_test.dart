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

  testWidgets('editing a slot recipe link and saving persists the new link', (tester) async {
    final repository = MealHistoryRepository();
    await repository.saveWeek(_entry());

    await tester.pumpWidget(
      MaterialApp(home: HistoryDetailScreen(entry: _entry(), repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit this slot'));
    await tester.pumpAndSettle();

    final urlField = find.widgetWithText(TextField, 'Recipe link (optional)').first;
    await tester.enterText(urlField, 'https://example.com/general-tao-chicken');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    final saved = await repository.loadAll();
    expect(saved.single.slots.single.proteinComponent.recipeUrl, 'https://example.com/general-tao-chicken');
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
    // chip is the second of the three sections' chips. The dialog content
    // is taller than the test surface, so scroll it into view before tapping.
    final addVegetableAnchor = find.text('Add anchor').at(2);
    await tester.ensureVisible(addVegetableAnchor);
    await tester.pumpAndSettle();
    await tester.tap(addVegetableAnchor);
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
    await tester.ensureVisible(find.text('Broccoli · IGA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Broccoli · IGA'));
    await tester.pumpAndSettle();
    expect(find.text('Edit anchor item'), findsOneWidget);
    // Two "Cancel" buttons are in the tree at once - the edit-slot dialog's
    // own Cancel sits behind this anchor dialog - so target the topmost one.
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.text('Broccoli · IGA'), findsOneWidget);

    // Editing again and saving updates the chip.
    await tester.ensureVisible(find.text('Broccoli · IGA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Broccoli · IGA'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Item name'), 'Carrots');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Carrots · IGA'), findsOneWidget);
    expect(find.text('Broccoli · IGA'), findsNothing);

    // Removing it via the chip's delete icon.
    final chip = find.ancestor(of: find.text('Carrots · IGA'), matching: find.byType(InputChip));
    final deleteIcon = find.descendant(of: chip, matching: find.byIcon(Icons.close));
    await tester.ensureVisible(deleteIcon);
    await tester.pumpAndSettle();
    await tester.tap(deleteIcon);
    await tester.pumpAndSettle();

    expect(find.text('Carrots · IGA'), findsNothing);
  });

  testWidgets('cancelling the date picker leaves the week unchanged', (tester) async {
    final repository = MealHistoryRepository();
    await repository.saveWeek(_entry());

    await tester.pumpWidget(
      MaterialApp(home: HistoryDetailScreen(entry: _entry(), repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Change week'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('2026-W34'), findsOneWidget);
    expect(find.text('Save changes'), findsNothing);
  });

  testWidgets('picking a date in the same week is a no-op', (tester) async {
    final repository = MealHistoryRepository();
    await repository.saveWeek(_entry());

    await tester.pumpWidget(
      MaterialApp(home: HistoryDetailScreen(entry: _entry(), repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Change week'));
    await tester.pumpAndSettle();

    // Switch to keyboard entry and pick a different day within the same
    // ISO week (2026-08-17 is that week's Monday).
    await tester.tap(find.byIcon(Icons.edit_outlined).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '08/17/2026');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('2026-W34'), findsOneWidget);
    expect(find.text('Save changes'), findsNothing);
  });

  testWidgets('moves the entry to a new week on save', (tester) async {
    final repository = MealHistoryRepository();
    await repository.saveWeek(_entry());

    await tester.pumpWidget(
      MaterialApp(home: HistoryDetailScreen(entry: _entry(), repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Change week'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined).last);
    await tester.pumpAndSettle();
    // 2026-08-24 is the Monday of the following ISO week (2026-W35).
    await tester.enterText(find.byType(TextField), '08/24/2026');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('2026-W35'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    final all = await repository.loadAll();
    expect(all.map((e) => e.weekId), ['2026-W35']);
    expect(all.single.slots.single.recipeName, 'General Tao Chicken');
  });

  testWidgets('moving to a week that already has a plan asks to confirm, and Cancel leaves both intact', (
    tester,
  ) async {
    final repository = MealHistoryRepository();
    await repository.saveWeek(_entry());
    await repository.saveWeek(
      MealHistoryEntry(weekId: '2026-W35', savedAt: DateTime.utc(2026, 8, 27), slots: _entry().slots),
    );

    await tester.pumpWidget(
      MaterialApp(home: HistoryDetailScreen(entry: _entry(), repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Change week'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '08/24/2026');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('Replace existing plan?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('2026-W34'), findsOneWidget);
    expect(find.text('Save changes'), findsNothing);
    expect((await repository.loadAll()).length, 2);
  });

  testWidgets('confirming the replacement moves the entry and overwrites the target week', (tester) async {
    final repository = MealHistoryRepository();
    await repository.saveWeek(_entry());
    await repository.saveWeek(
      MealHistoryEntry(
        weekId: '2026-W35',
        savedAt: DateTime.utc(2026, 8, 27),
        slots: [
          const MealSlotFull(
            mealType: MealType.supper,
            protein: 'tofu',
            count: 4,
            portionsPerMeal: 3,
            proteinComponent: MealComponent(type: MealComponentType.aiRecipe, name: 'Tofu curry', usesWeeklyDeal: false),
            carbComponent: MealComponent(type: MealComponentType.simpleSide, name: 'Rice', usesWeeklyDeal: false),
            vegetableComponent: MealComponent(
              type: MealComponentType.simpleSide,
              name: 'Green beans',
              usesWeeklyDeal: false,
            ),
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: HistoryDetailScreen(entry: _entry(), repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Change week'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '08/24/2026');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();

    expect(find.text('2026-W35'), findsOneWidget);
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    final all = await repository.loadAll();
    expect(all.map((e) => e.weekId), ['2026-W35']);
    expect(all.single.slots.single.recipeName, 'General Tao Chicken');
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
