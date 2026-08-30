import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/store_config.dart';
import 'package:laplanif/screens/config_stores_screen.dart';
import 'package:laplanif/services/store_config_repository.dart';

class _SlowStoreConfigRepository extends StoreConfigRepository {
  _SlowStoreConfigRepository(this._future);

  final Future<List<StoreConfig>> _future;

  @override
  Future<List<StoreConfig>> load() => _future;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(WidgetTester tester, StoreConfigRepository repo) async {
    await tester.pumpWidget(MaterialApp(home: ConfigStoresScreen(repository: repo)));
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

    await tester.tap(find.byTooltip('Add store'));
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

  // Deal items are matched back to a store by display name on retry
  // (planif_screen._retryStore), so two stores sharing a name would
  // silently corrupt each other's results - the name field rejects a
  // duplicate rather than letting that happen.
  testWidgets('rejects a store name that duplicates an existing store', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    await tester.tap(find.byTooltip('Add store'));
    await tester.pumpAndSettle();

    // Case/whitespace-insensitive: "  iga " still collides with "IGA".
    await tester.enterText(find.widgetWithText(TextFormField, 'Display name'), '  iga ');
    await tester.enterText(find.widgetWithText(TextFormField, 'Flyer URL'), 'https://example.com/another-iga');
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(find.text('A store with this name already exists'), findsOneWidget);

    final saved = await repo.load();
    expect(saved.where((s) => s.name.toLowerCase() == 'iga').length, 1);
  });

  testWidgets('allows saving a store with its own unchanged name', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    await tester.tap(find.text('Metro'));
    await tester.pumpAndSettle();

    // Editing the URL but leaving the name as-is shouldn't trip the
    // duplicate-name check against itself.
    await tester.enterText(find.widgetWithText(TextFormField, 'Flyer URL'), 'https://example.com/metro-updated');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('A store with this name already exists'), findsNothing);
    final saved = await repo.load();
    expect(saved.firstWhere((s) => s.id == 'metro').flyerUrl, 'https://example.com/metro-updated');
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
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    final saved = await repo.load();
    expect(saved.length, 2);
  });

  testWidgets('cancelling the delete confirmation keeps the store', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final saved = await repo.load();
    expect(saved.length, 3);
  });

  testWidgets('shows empty state once every store is removed', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
    }

    expect(find.text('No stores configured yet.'), findsOneWidget);
  });

  testWidgets('disables Add store until the list has loaded', (tester) async {
    final storesCompleter = Completer<List<StoreConfig>>();
    final repo = _SlowStoreConfigRepository(storesCompleter.future);

    await tester.pumpWidget(MaterialApp(home: ConfigStoresScreen(repository: repo)));
    await tester.pump();

    IconButton addStoreButton() =>
        tester.widget<IconButton>(find.ancestor(of: find.byTooltip('Add store'), matching: find.byType(IconButton)));

    expect(addStoreButton().onPressed, isNull);

    storesCompleter.complete(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);
    await tester.pumpAndSettle();

    expect(addStoreButton().onPressed, isNotNull);
  });
}
