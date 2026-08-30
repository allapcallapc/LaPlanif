import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/screens/config_ai_screen.dart';
import 'package:laplanif/services/ai_config_repository.dart';

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

  // Tall enough that every row (API key field, both model lists, usage log
  // tile) is laid out without needing to scroll - find.*/tap() only see
  // widgets that are actually built, and the default 800x600 test surface
  // is shorter than this screen's full content once a few models are
  // configured.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpScreen(WidgetTester tester, AiConfigRepository repo) async {
    useTallSurface(tester);
    await tester.pumpWidget(MaterialApp(home: ConfigAiScreen(repository: repo)));
    await tester.pumpAndSettle();
  }

  testWidgets('saves the API key as it is typed and reloads it on next open', (tester) async {
    final repo = AiConfigRepository();
    await pumpScreen(tester, repo);

    await tester.enterText(find.widgetWithText(TextField, 'Google AI API key'), 'test-google-ai-key');
    // The save is debounced; advance past the debounce window rather than
    // asserting it wrote synchronously on every keystroke.
    await tester.pump(const Duration(milliseconds: 600));

    expect(await repo.loadApiKey(), 'test-google-ai-key');

    await pumpScreen(tester, repo);

    expect(find.text('test-google-ai-key'), findsOneWidget);
  });

  testWidgets('debounces API key saves instead of writing on every keystroke', (tester) async {
    final repo = AiConfigRepository();
    await pumpScreen(tester, repo);

    final field = find.widgetWithText(TextField, 'Google AI API key');
    await tester.enterText(field, 't');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(field, 'te');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(field, 'test-key');

    // Still inside the debounce window from the last keystroke - nothing
    // written yet.
    expect(await repo.loadApiKey(), isEmpty);

    await tester.pump(const Duration(milliseconds: 600));

    // One coalesced write of the final value once typing settles.
    expect(await repo.loadApiKey(), 'test-key');
  });

  testWidgets('flushes a pending API key save when disposed before the debounce fires', (tester) async {
    final repo = AiConfigRepository();
    await pumpScreen(tester, repo);

    await tester.enterText(find.widgetWithText(TextField, 'Google AI API key'), 'unsaved-key');
    // Still inside the debounce window - nothing written yet.
    await tester.pump(const Duration(milliseconds: 100));
    expect(await repo.loadApiKey(), isEmpty);

    // Navigate away before the debounce fires, disposing the screen.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    // The pending save was flushed rather than dropped.
    expect(await repo.loadApiKey(), 'unsaved-key');
  });

  testWidgets('disables Add model until the list has loaded', (tester) async {
    final modelsCompleter = Completer<List<String>>();
    final repo = _SlowAiConfigRepository(modelsCompleter.future);

    useTallSurface(tester);
    await tester.pumpWidget(MaterialApp(home: ConfigAiScreen(repository: repo)));
    await tester.pump();

    IconButton addModelButton() =>
        tester.widget<IconButton>(find.ancestor(of: find.byTooltip('Add model'), matching: find.byType(IconButton)));

    expect(addModelButton().onPressed, isNull);

    modelsCompleter.complete(['model-a']);
    await tester.pumpAndSettle();

    expect(addModelButton().onPressed, isNotNull);
  });

  testWidgets('toggles the API key visibility icon', (tester) async {
    final repo = AiConfigRepository();
    await pumpScreen(tester, repo);

    expect(find.byIcon(Icons.visibility), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off), findsNothing);

    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
  });

  testWidgets('navigates to the AI usage log', (tester) async {
    final repo = AiConfigRepository();
    await pumpScreen(tester, repo);

    await tester.tap(find.text('AI usage log'));
    await tester.pumpAndSettle();

    expect(find.text('AI Usage Log'), findsOneWidget);
    expect(find.text('No AI calls yet.'), findsOneWidget);
  });

  testWidgets('shows the full default model list with gemini-3.5-flash-lite first', (tester) async {
    final repo = AiConfigRepository();
    await pumpScreen(tester, repo);

    // The default grounding-model list is the same as the default model
    // list, so every entry renders twice: once in each section.
    for (final model in AiConfigRepository.defaultModels) {
      expect(find.text(model), findsNWidgets(2));
    }
    expect(AiConfigRepository.defaultModels.first, 'gemini-3.5-flash-lite');
  });

  testWidgets('shows the full default grounding-model list, matching the general model list', (tester) async {
    final repo = AiConfigRepository();
    await pumpScreen(tester, repo);

    for (final model in AiConfigRepository.defaultGroundingModels) {
      expect(find.text(model), findsNWidgets(2));
    }
    expect(AiConfigRepository.defaultGroundingModels, AiConfigRepository.defaultModels);
  });

  testWidgets('disables removal when only one grounding model is configured', (tester) async {
    final repo = AiConfigRepository();
    await repo.saveGroundingModels(['solo-grounding-model']);
    await pumpScreen(tester, repo);

    expect(find.text('solo-grounding-model'), findsOneWidget);
    final removeButton = tester.widget<IconButton>(
      find.ancestor(of: find.byTooltip('Remove grounding model'), matching: find.byType(IconButton)),
    );
    expect(removeButton.onPressed, isNull);
  });

  testWidgets('adds a grounding model and persists the order', (tester) async {
    final repo = AiConfigRepository();
    await pumpScreen(tester, repo);

    await tester.tap(find.byTooltip('Add grounding model'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Model id'), 'gemini-grounding-backup');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('gemini-grounding-backup'), findsOneWidget);
    expect(await repo.loadGroundingModels(), [...AiConfigRepository.defaultGroundingModels, 'gemini-grounding-backup']);
  });

  testWidgets('editing a grounding model updates it in place', (tester) async {
    final repo = AiConfigRepository();
    await pumpScreen(tester, repo);

    // gemini-3.5-flash-lite appears in both the general model list and the
    // grounding-model list - .first resolves to the general list's row,
    // .last to the grounding list's row, since the grounding section renders
    // below it.
    await tester.tap(find.text('gemini-3.5-flash-lite').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Model id'), 'gemini-grounding-renamed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('gemini-grounding-renamed'), findsOneWidget);
    expect(await repo.loadGroundingModels(), [
      'gemini-grounding-renamed',
      ...AiConfigRepository.defaultGroundingModels.skip(1),
    ]);
  });

  testWidgets('reorders grounding models with the move arrows and persists the new order', (tester) async {
    final repo = AiConfigRepository();
    await repo.saveGroundingModels(['gemini-a', 'gemini-b']);
    await pumpScreen(tester, repo);

    await tester.tap(find.byTooltip('Move grounding model up').last);
    await tester.pumpAndSettle();

    expect(await repo.loadGroundingModels(), ['gemini-b', 'gemini-a']);
  });

  testWidgets('reorders grounding models with the move-down arrow and persists the new order', (tester) async {
    final repo = AiConfigRepository();
    await repo.saveGroundingModels(['gemini-a', 'gemini-b']);
    await pumpScreen(tester, repo);

    await tester.tap(find.byTooltip('Move grounding model down').first);
    await tester.pumpAndSettle();

    expect(await repo.loadGroundingModels(), ['gemini-b', 'gemini-a']);
  });

  testWidgets('removes a grounding model when more than one is configured', (tester) async {
    final repo = AiConfigRepository();
    await repo.saveGroundingModels(['gemini-a', 'gemini-b']);
    await pumpScreen(tester, repo);

    await tester.tap(find.byTooltip('Remove grounding model').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(await repo.loadGroundingModels(), ['gemini-b']);
  });

  testWidgets('disables removal when only one model is configured', (tester) async {
    final repo = AiConfigRepository();
    await repo.saveModels(['solo-model']);
    await pumpScreen(tester, repo);

    expect(find.text('solo-model'), findsOneWidget);
    final removeButton = tester.widget<IconButton>(
      find.ancestor(of: find.byTooltip('Remove model'), matching: find.byType(IconButton)),
    );
    expect(removeButton.onPressed, isNull);
  });

  testWidgets('adds a model and persists the order', (tester) async {
    final repo = AiConfigRepository();
    await pumpScreen(tester, repo);

    await tester.tap(find.byTooltip('Add model'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Model id'), 'gemini-backup');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('gemini-backup'), findsOneWidget);
    expect(await repo.loadModels(), [...AiConfigRepository.defaultModels, 'gemini-backup']);
  });

  testWidgets('editing a model updates it in place', (tester) async {
    final repo = AiConfigRepository();
    await pumpScreen(tester, repo);

    // gemini-3.5-flash-lite also appears in the grounding-model section
    // below (same default list) - .first is the general Models section's row.
    await tester.tap(find.text('gemini-3.5-flash-lite').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Model id'), 'gemini-renamed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('gemini-renamed'), findsOneWidget);
    expect(await repo.loadModels(), ['gemini-renamed', ...AiConfigRepository.defaultModels.skip(1)]);
  });

  testWidgets('reorders models with the move arrows and persists the new order', (tester) async {
    final repo = AiConfigRepository();
    await repo.saveModels(['gemini-a', 'gemini-b']);
    await pumpScreen(tester, repo);

    await tester.tap(find.byTooltip('Move up').last);
    await tester.pumpAndSettle();

    expect(await repo.loadModels(), ['gemini-b', 'gemini-a']);
  });

  testWidgets('removes a model when more than one is configured', (tester) async {
    final repo = AiConfigRepository();
    await repo.saveModels(['gemini-a', 'gemini-b']);
    await pumpScreen(tester, repo);

    await tester.tap(find.byTooltip('Remove model').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('gemini-a'), findsNothing);
    expect(await repo.loadModels(), ['gemini-b']);
  });
}
