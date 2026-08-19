import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/main.dart';

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
    expect(stack.index, 1);
  });
}
