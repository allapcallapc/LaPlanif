import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/models/meal_plan_preview.dart';
import 'package:laplanif/widgets/carb_picker_dialog.dart';

void main() {
  const deals = [
    DealItem(
      name: 'Spaghetti',
      price: '1.49',
      unit: '',
      category: DealCategory.carbs,
      storeName: 'IGA',
      pageIndex: 2,
      preference: DealPreference.priority,
    ),
    DealItem(name: 'Naan bread', price: '2.99', unit: '', category: DealCategory.carbs, storeName: 'Metro', pageIndex: 3),
  ];

  // What the last-closed picker resolved to, and whether it has closed.
  AnchorItem? picked;
  var closed = false;

  Future<void> pumpAndOpen(WidgetTester tester, {List<DealItem> deals = deals, Set<String> used = const {}}) async {
    picked = null;
    closed = false;
    // Tall enough for the whole dialog to be on screen.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                picked = await showCarbPickerDialog(context, deals: deals, usedElsewhere: used);
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists carb deals, starring priority ones and flagging ones used in another meal', (tester) async {
    await pumpAndOpen(tester, used: {'naan bread', 'quinoa'});

    expect(find.text('On sale this week'), findsOneWidget);
    expect(find.widgetWithIcon(ListTile, Icons.star), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Spaghetti'), findsOneWidget);
    expect(find.text('IGA'), findsOneWidget);
    expect(find.text('Metro · in another meal'), findsOneWidget);
    expect(find.byTooltip('Already in another meal'), findsOneWidget);

    await tester.tap(find.text('Spaghetti'));
    await tester.pumpAndSettle();
    expect(picked?.name, 'Spaghetti');
    expect(picked?.store, 'IGA');
    expect(picked?.isPantry, isFalse);
  });

  testWidgets('hides the deals section when no carb is on sale, and picks a pantry staple', (tester) async {
    await pumpAndOpen(tester, deals: const []);

    expect(find.text('On sale this week'), findsNothing);
    for (final name in pantryCarbs) {
      expect(find.text(name), findsOneWidget);
    }

    await tester.tap(find.text('Couscous'));
    await tester.pumpAndSettle();
    expect(picked?.name, 'Couscous');
    expect(picked?.isPantry, isTrue);
  });

  testWidgets('a typed carb is used on Enter as a pantry item, trimmed, and blank input is ignored', (tester) async {
    await pumpAndOpen(tester);

    // Blank (or whitespace-only) input does nothing, the dialog stays open.
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Use'));
    await tester.pumpAndSettle();
    expect(closed, isFalse);
    expect(find.text('Choose a carb'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '  Polenta ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(picked?.name, 'Polenta');
    expect(picked?.isPantry, isTrue);
    expect(picked?.store, AnchorItem.pantryStore);
  });

  testWidgets('Cancel closes without picking anything', (tester) async {
    await pumpAndOpen(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(picked, isNull);
  });
}
