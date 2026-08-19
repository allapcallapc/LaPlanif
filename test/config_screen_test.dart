import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/store_config.dart';
import 'package:laplanif/screens/config_screen.dart';
import 'package:laplanif/services/ai_config_repository.dart';
import 'package:laplanif/services/store_config_repository.dart';

class _SlowStoreConfigRepository extends StoreConfigRepository {
  _SlowStoreConfigRepository(this._future);

  final Future<List<StoreConfig>> _future;

  @override
  Future<List<StoreConfig>> load() => _future;
}

class _SlowAiConfigRepository extends AiConfigRepository {
  _SlowAiConfigRepository(this._modelsFuture);

  final Future<List<String>> _modelsFuture;

  @override
  Future<String> loadApiKey() async => '';

  @override
  Future<List<String>> loadModels() => _modelsFuture;
}

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
    tester.view.physicalSize = const Size(800, 2200);
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
    // The save is debounced; advance past the debounce window rather than
    // asserting it wrote synchronously on every keystroke.
    await tester.pump(const Duration(milliseconds: 600));

    expect(await aiConfigRepo.loadApiKey(), 'test-google-ai-key');

    await pumpScreen(tester, storeRepo, aiConfigRepository: aiConfigRepo);

    expect(find.text('test-google-ai-key'), findsOneWidget);
  });

  testWidgets('debounces API key saves instead of writing on every keystroke', (tester) async {
    final storeRepo = StoreConfigRepository();
    final aiConfigRepo = AiConfigRepository();

    await pumpScreen(tester, storeRepo, aiConfigRepository: aiConfigRepo);

    final field = find.widgetWithText(TextField, 'Google AI API key');
    await tester.enterText(field, 't');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(field, 'te');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(field, 'test-key');

    // Still inside the debounce window from the last keystroke - nothing
    // written yet.
    expect(await aiConfigRepo.loadApiKey(), isEmpty);

    await tester.pump(const Duration(milliseconds: 600));

    // One coalesced write of the final value once typing settles.
    expect(await aiConfigRepo.loadApiKey(), 'test-key');
  });

  testWidgets('flushes a pending API key save when disposed before the debounce fires', (tester) async {
    final storeRepo = StoreConfigRepository();
    final aiConfigRepo = AiConfigRepository();

    await pumpScreen(tester, storeRepo, aiConfigRepository: aiConfigRepo);

    await tester.enterText(find.widgetWithText(TextField, 'Google AI API key'), 'unsaved-key');
    // Still inside the debounce window - nothing written yet.
    await tester.pump(const Duration(milliseconds: 100));
    expect(await aiConfigRepo.loadApiKey(), isEmpty);

    // Navigate away before the debounce fires, disposing the ConfigScreen.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    // The pending save was flushed rather than dropped.
    expect(await aiConfigRepo.loadApiKey(), 'unsaved-key');
  });

  testWidgets('disables Add store and Add model until their lists have loaded', (tester) async {
    final storesCompleter = Completer<List<StoreConfig>>();
    final modelsCompleter = Completer<List<String>>();
    final repo = _SlowStoreConfigRepository(storesCompleter.future);
    final aiConfigRepo = _SlowAiConfigRepository(modelsCompleter.future);

    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(home: ConfigScreen(repository: repo, aiConfigRepository: aiConfigRepo)));
    await tester.pump();

    IconButton addStoreButton() =>
        tester.widget<IconButton>(find.ancestor(of: find.byTooltip('Add store'), matching: find.byType(IconButton)));
    IconButton addModelButton() =>
        tester.widget<IconButton>(find.ancestor(of: find.byTooltip('Add model'), matching: find.byType(IconButton)));

    expect(addStoreButton().onPressed, isNull);
    expect(addModelButton().onPressed, isNull);

    storesCompleter.complete(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);
    modelsCompleter.complete(['model-a']);
    await tester.pumpAndSettle();

    expect(addStoreButton().onPressed, isNotNull);
    expect(addModelButton().onPressed, isNotNull);
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

  testWidgets('shows the full default model list with gemini-3.5-flash-lite first', (tester) async {
    final repo = StoreConfigRepository();
    await pumpScreen(tester, repo);

    for (final model in AiConfigRepository.defaultModels) {
      expect(find.text(model), findsOneWidget);
    }
    expect(AiConfigRepository.defaultModels.first, 'gemini-3.5-flash-lite');
  });

  testWidgets('disables removal when only one model is configured', (tester) async {
    final storeRepo = StoreConfigRepository();
    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveModels(['solo-model']);
    await pumpScreen(tester, storeRepo, aiConfigRepository: aiConfigRepo);

    expect(find.text('solo-model'), findsOneWidget);
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
    expect(await aiConfigRepo.loadModels(), [...AiConfigRepository.defaultModels, 'gemini-backup']);
  });

  testWidgets('editing a model updates it in place', (tester) async {
    final storeRepo = StoreConfigRepository();
    final aiConfigRepo = AiConfigRepository();
    await pumpScreen(tester, storeRepo, aiConfigRepository: aiConfigRepo);

    await tester.tap(find.text('gemini-3.5-flash-lite'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Model id'), 'gemini-renamed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('gemini-renamed'), findsOneWidget);
    expect(await aiConfigRepo.loadModels(), [
      'gemini-renamed',
      ...AiConfigRepository.defaultModels.skip(1),
    ]);
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
