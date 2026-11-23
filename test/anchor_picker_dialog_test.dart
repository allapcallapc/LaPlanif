import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/models/meal_plan_preview.dart';
import 'package:laplanif/widgets/anchor_picker_dialog.dart';

void main() {
  const items = [
    DealItem(
      name: 'Ground pork',
      price: '3.99',
      unit: 'lb',
      category: DealCategory.protein,
      storeName: 'IGA',
      pageIndex: 3,
    ),
    DealItem(
      name: 'Chicken thighs',
      price: '4.99',
      unit: 'lb',
      category: DealCategory.protein,
      storeName: 'Metro',
      pageIndex: 2,
      preference: DealPreference.priority,
    ),
    DealItem(
      name: 'Brocoli',
      price: '1.99',
      unit: '',
      category: DealCategory.vegetables,
      storeName: 'IGA',
      pageIndex: 1,
    ),
    DealItem(name: 'Rice', price: '5.99', unit: '', category: DealCategory.carbs, storeName: 'Metro', pageIndex: 4),
  ];

  // What the last-closed picker resolved to.
  DealItem? picked;

  Future<void> pumpAndOpen(WidgetTester tester, List<DealItem> items, {DealCategory? initialCategory}) async {
    picked = null;
    // Tall enough for every row to be built, so off-screen items don't read
    // as filtered out.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async =>
                  picked = await showAnchorPickerDialog(
                context,
                items: items,
                title: 'Add anchor item',
                initialCategory: initialCategory,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder chip(String label) => find.widgetWithText(ChoiceChip, label);

  double dy(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

  testWidgets('groups items under category headers in the deals list order', (tester) async {
    await pumpAndOpen(tester, items);

    expect(find.text('Add anchor item'), findsOneWidget);
    // Sections follow the deals list's order: protein, vegetables, carbs.
    expect(dy(tester, 'Chicken thighs'), lessThan(dy(tester, 'Brocoli')));
    expect(dy(tester, 'Brocoli'), lessThan(dy(tester, 'Rice')));
    // Once as the section header, once as its filter chip.
    expect(find.text('Protein'), findsNWidgets(2));
    expect(find.byIcon(Icons.star), findsOneWidget);
    // Priority items float to the top of their section.
    expect(dy(tester, 'Chicken thighs'), lessThan(dy(tester, 'Ground pork')));
  });

  testWidgets('filters by store and by category', (tester) async {
    await pumpAndOpen(tester, items);

    await tester.tap(chip('Metro'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Chicken thighs'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Rice'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Ground pork'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Brocoli'), findsNothing);
    // Metro has no vegetables, so that category isn't offered as a filter.
    expect(chip('Vegetables'), findsNothing);

    await tester.tap(chip('Carbs'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Rice'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Chicken thighs'), findsNothing);

    await tester.tap(chip('All stores'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Rice'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Brocoli'), findsNothing);
  });

  testWidgets('falls back to all categories when a store change empties the picked one', (tester) async {
    await pumpAndOpen(tester, items);

    await tester.tap(chip('Vegetables'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Brocoli'), findsOneWidget);

    await tester.tap(chip('Metro'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Chicken thighs'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Rice'), findsOneWidget);
  });

  testWidgets('narrows the list by a name search', (tester) async {
    await pumpAndOpen(tester, items);

    await tester.enterText(find.byType(TextField), 'PORK');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Ground pork'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Chicken thighs'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No items match the current filters.'), findsOneWidget);
  });

  testWidgets('returns the tapped item, or null on cancel', (tester) async {
    await pumpAndOpen(tester, items);
    await tester.tap(find.text('Rice'));
    await tester.pumpAndSettle();
    expect(picked?.name, 'Rice');

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(picked, isNull);
  });

  testWidgets('says so when there is nothing left to pick', (tester) async {
    await pumpAndOpen(tester, const []);
    expect(find.text('No available deal items.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('opens on the initial category, which can still be changed', (tester) async {
    await pumpAndOpen(tester, items, initialCategory: DealCategory.vegetables);

    expect(tester.widget<ChoiceChip>(chip('Vegetables')).selected, isTrue);
    expect(find.text('Brocoli'), findsOneWidget);
    expect(find.text('Chicken thighs'), findsNothing);

    await tester.tap(chip('All'));
    await tester.pumpAndSettle();
    expect(find.text('Chicken thighs'), findsOneWidget);
  });

  testWidgets('as an ingredient picker, returns a deal or a typed-in ingredient in the given role', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AnchorItem? result;
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                closed = false;
                result = await showIngredientPickerDialog(
                  context,
                  items: items,
                  title: 'Choose a vegetable',
                  role: AnchorRole.vegetable,
                );
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    final custom = find.widgetWithText(TextField, 'Not on sale? Type an ingredient');

    // A deal comes back as that part of the meal.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Brocoli'));
    await tester.pumpAndSettle();
    expect(result?.name, 'Brocoli');
    expect(result?.store, 'IGA');
    expect(result?.role, AnchorRole.vegetable);
    expect(result?.isPantry, isFalse);

    // Blank input is ignored; a typed name is used on Enter, trimmed.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(custom, '  ');
    await tester.tap(find.text('Use'));
    await tester.pumpAndSettle();
    expect(closed, isFalse);
    await tester.enterText(custom, ' Kale ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result?.name, 'Kale');
    expect(result?.isPantry, isTrue);
    expect(result?.role, AnchorRole.vegetable);

    // Cancel gives nothing.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('the plain deal picker has no typed-in option', (tester) async {
    await pumpAndOpen(tester, items);
    expect(find.text('Not on sale? Type an ingredient'), findsNothing);
  });
}
