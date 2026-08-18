import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/screens/store_config_screen.dart';
import 'package:laplanif/services/store_config_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(WidgetTester tester, StoreConfigRepository repo) async {
    await tester.pumpWidget(MaterialApp(home: StoreConfigScreen(repository: repo)));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the default stores', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    expect(find.text('IGA'), findsOneWidget);
    expect(find.textContaining('circulaire-iga-epicerie'), findsOneWidget);
    expect(find.text('Metro'), findsOneWidget);
    expect(find.textContaining('circulaire-metro-speciaux'), findsOneWidget);
    expect(find.text('Maxi'), findsOneWidget);
  });

  testWidgets('adding a store requires both fields and rejects a bad URL', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Required'), findsNWidgets(2));

    await tester.enterText(find.widgetWithText(TextFormField, 'Display name'), 'Super C');
    await tester.enterText(find.widgetWithText(TextFormField, 'Flyer URL'), 'not a url');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Enter a valid URL'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Flyer URL'), 'https://example.com/super-c');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Super C'), findsOneWidget);
    expect(find.textContaining('example.com/super-c'), findsOneWidget);

    final saved = await repo.load();
    expect(saved.any((s) => s.name == 'Super C' && s.flyerUrl == 'https://example.com/super-c'), isTrue);
  });

  testWidgets('editing a store updates it in place', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    await tester.tap(find.text('Metro'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Display name'), 'Metro Plus');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Metro Plus'), findsOneWidget);
    expect(find.text('Metro'), findsNothing);

    final saved = await repo.load();
    expect(saved.firstWhere((s) => s.id == 'metro').name, 'Metro Plus');
  });

  testWidgets('cancel discards the edit', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    await tester.tap(find.text('Maxi'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Maxi'), findsOneWidget);
  });

  testWidgets('removing a store deletes it and persists', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();

    final saved = await repo.load();
    expect(saved.length, 2);
  });

  testWidgets('shows empty state once every store is removed', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
    }

    expect(find.text('No stores configured yet.'), findsOneWidget);
  });
}
