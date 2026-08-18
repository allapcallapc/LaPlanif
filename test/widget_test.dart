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

  testWidgets('default store list is preconfigured', (WidgetTester tester) async {
    await tester.pumpWidget(const LaPlanifApp());
    await tester.pumpAndSettle();

    expect(find.text('IGA'), findsOneWidget);
    expect(find.text('Metro'), findsOneWidget);
    expect(find.text('Maxi'), findsOneWidget);
  });

  testWidgets('tapping the Config destination switches tabs', (WidgetTester tester) async {
    await tester.pumpWidget(const LaPlanifApp());
    await tester.pumpAndSettle();

    // Both the nav label and the Config screen's own AppBar title read
    // "Config" (the latter stays mounted offstage via IndexedStack), so the
    // tap must be scoped to the NavigationBar to hit the destination.
    final configDestination = find.descendant(of: find.byType(NavigationBar), matching: find.text('Config'));
    await tester.tap(configDestination);
    await tester.pumpAndSettle();

    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.index, 1);
  });
}
