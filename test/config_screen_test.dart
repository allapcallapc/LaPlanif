import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/screens/config_screen.dart';
import 'package:laplanif/services/ai_config_repository.dart';
import 'package:laplanif/services/store_config_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // Tall enough that every row (stores, API key field, models, usage log
  // tile) is laid out without needing to scroll - find.*/tap() only see
  // widgets that are actually built, and the default 800x600 test surface
  // is shorter than this screen's full content once a few models are
  // configured.
  Future<void> pumpScreen(
    WidgetTester tester,
    StoreConfigRepository repo, {
    AiConfigRepository? aiConfigRepository,
  }) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(home: ConfigScreen(repository: repo, aiConfigRepository: aiConfigRepository)),
    );
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

  testWidgets('saves the API key as it is typed and reloads it on next open', (tester) async {
    final storeRepo = StoreConfigRepository();
    final aiConfigRepo = AiConfigRepository();

    await pumpScreen(tester, storeRepo, aiConfigRepository: aiConfigRepo);

    await tester.enterText(find.widgetWithText(TextField, 'Google AI API key'), 'test-google-ai-key');
    await tester.pump();

    expect(await aiConfigRepo.loadApiKey(), 'test-google-ai-key');

    await pumpScreen(tester, storeRepo, aiConfigRepository: aiConfigRepo);

    expect(find.text('test-google-ai-key'), findsOneWidget);
  });

  testWidgets('toggles the API key visibility icon', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    expect(find.byIcon(Icons.visibility), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off), findsNothing);

    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
  });

  testWidgets('navigates to the AI usage log', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    await tester.tap(find.text('AI usage log'));
    await tester.pumpAndSettle();

    expect(find.text('AI Usage Log'), findsOneWidget);
    expect(find.text('No AI calls yet.'), findsOneWidget);
  });

  testWidgets('shows the single default model with removal disabled', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    expect(find.text('gemini-3.6-flash'), findsOneWidget);
    final removeButton = tester.widget<IconButton>(
      find.ancestor(of: find.byTooltip('Remove model'), matching: find.byType(IconButton)),
    );
    expect(removeButton.onPressed, isNull);
  });

  testWidgets('adds a model and persists the order', (tester) async {
    final storeRepo = StoreConfigRepository();
    final aiConfigRepo = AiConfigRepository();
    await pumpScreen(tester, storeRepo, aiConfigRepository: aiConfigRepo);

    await tester.tap(find.byTooltip('Add model'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Model id'), 'gemini-backup');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('gemini-backup'), findsOneWidget);
    expect(await aiConfigRepo.loadModels(), ['gemini-3.6-flash', 'gemini-backup']);
  });

  testWidgets('editing a model updates it in place', (tester) async {
    final storeRepo = StoreConfigRepository();
    final aiConfigRepo = AiConfigRepository();
    await pumpScreen(tester, storeRepo, aiConfigRepository: aiConfigRepo);

    await tester.tap(find.text('gemini-3.6-flash'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Model id'), 'gemini-renamed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('gemini-renamed'), findsOneWidget);
    expect(await aiConfigRepo.loadModels(), ['gemini-renamed']);
  });

  testWidgets('reorders models with the move arrows and persists the new order', (tester) async {
    final storeRepo = StoreConfigRepository();
    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveModels(['gemini-a', 'gemini-b']);
    await pumpScreen(tester, storeRepo, aiConfigRepository: aiConfigRepo);

    await tester.tap(find.byTooltip('Move up').last);
    await tester.pumpAndSettle();

    expect(await aiConfigRepo.loadModels(), ['gemini-b', 'gemini-a']);
  });

  testWidgets('removes a model when more than one is configured', (tester) async {
    final storeRepo = StoreConfigRepository();
    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveModels(['gemini-a', 'gemini-b']);
    await pumpScreen(tester, storeRepo, aiConfigRepository: aiConfigRepo);

    await tester.tap(find.byTooltip('Remove model').first);
    await tester.pumpAndSettle();

    expect(find.text('gemini-a'), findsNothing);
    expect(await aiConfigRepo.loadModels(), ['gemini-b']);
  });
}
