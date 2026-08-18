import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/main.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows the Stores and Deals tabs', (WidgetTester tester) async {
    await tester.pumpWidget(const LaPlanifApp());
    await tester.pumpAndSettle();

    expect(find.text('Stores'), findsWidgets);
    expect(find.text('Deals'), findsWidgets);
  });

  testWidgets('default store list is preconfigured', (WidgetTester tester) async {
    await tester.pumpWidget(const LaPlanifApp());
    await tester.pumpAndSettle();

    expect(find.text('IGA'), findsOneWidget);
    expect(find.text('Metro'), findsOneWidget);
    expect(find.text('Maxi'), findsOneWidget);
  });

  testWidgets('tapping the Deals destination switches tabs', (WidgetTester tester) async {
    await tester.pumpWidget(const LaPlanifApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Deals'));
    await tester.pumpAndSettle();

    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.index, 1);
  });
}
