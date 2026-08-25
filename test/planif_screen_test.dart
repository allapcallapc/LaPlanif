import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/models/flyer_page.dart';
import 'package:laplanif/models/meal_history.dart';
import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_full.dart';
import 'package:laplanif/models/meal_plan_preview.dart';
import 'package:laplanif/models/store_config.dart';
import 'package:laplanif/screens/planif_screen.dart';
import 'package:laplanif/services/ai_config_repository.dart';
import 'package:laplanif/services/ai_deal_extraction_service.dart';
import 'package:laplanif/services/deal_cache_repository.dart';
import 'package:laplanif/services/deal_preference_repository.dart';
import 'package:laplanif/services/flyer_scraper_service.dart';
import 'package:laplanif/services/meal_history_repository.dart';
import 'package:laplanif/services/meal_plan_config_repository.dart';
import 'package:laplanif/services/meal_plan_generation_service.dart';
import 'package:laplanif/services/meal_plan_preview_service.dart';
import 'package:laplanif/services/model_fallback_controller.dart';
import 'package:laplanif/services/store_config_repository.dart';

class _FakePagesScraper extends FlyerScraperService {
  _FakePagesScraper(this._pages);

  final Map<String, List<FlyerPage>> _pages;

  @override
  Future<List<FlyerPage>> fetchPages(StoreConfig store) async {
    final pages = _pages[store.id];
    if (pages == null) throw Exception('no pages for ${store.id}');
    return pages;
  }
}

class _FakeExtractionService extends AiDealExtractionService {
  _FakeExtractionService(this._handlers);

  final Map<String, Future<List<DealItem>> Function()> _handlers;

  @override
  Future<List<DealItem>> extractItems({
    required String apiKey,
    required String storeName,
    required List<FlyerPage> pages,
    String? model,
  }) {
    final handler = _handlers[storeName];
    if (handler == null) throw Exception('no handler for $storeName');
    return handler();
  }
}

/// Extraction fake for exercising the model-fallback/rate-limit flow: the
/// caller decides what happens per model, independent of which store asked.
class _FakeModelAwareExtractionService extends AiDealExtractionService {
  _FakeModelAwareExtractionService(this._byModel);

  final Future<List<DealItem>> Function(String model, String storeName) _byModel;

  @override
  Future<List<DealItem>> extractItems({
    required String apiKey,
    required String storeName,
    required List<FlyerPage> pages,
    String? model,
  }) {
    return _byModel(model!, storeName);
  }
}

/// Extraction fake for exercising _fetchStore's own chunking: the caller
/// decides what happens per call, given which chunk of pages it was sent.
class _FakeChunkAwareExtractionService extends AiDealExtractionService {
  _FakeChunkAwareExtractionService(this._handler);

  final Future<List<DealItem>> Function(List<FlyerPage> pages, int callNumber) _handler;
  int _callCount = 0;

  @override
  Future<List<DealItem>> extractItems({
    required String apiKey,
    required String storeName,
    required List<FlyerPage> pages,
    String? model,
  }) {
    _callCount++;
    return _handler(pages, _callCount);
  }
}

/// Like _FakeChunkAwareExtractionService, but keyed per store so one store's
/// chunked behavior can be exercised while another store is held open.
class _FakeMultiStoreChunkAwareExtractionService extends AiDealExtractionService {
  _FakeMultiStoreChunkAwareExtractionService(this._handlers);

  final Map<String, Future<List<DealItem>> Function(List<FlyerPage> pages, int callNumber)> _handlers;
  final Map<String, int> _callCounts = {};

  @override
  Future<List<DealItem>> extractItems({
    required String apiKey,
    required String storeName,
    required List<FlyerPage> pages,
    String? model,
  }) {
    final handler = _handlers[storeName];
    if (handler == null) throw Exception('no handler for $storeName');
    final callNumber = (_callCounts[storeName] ?? 0) + 1;
    _callCounts[storeName] = callNumber;
    return handler(pages, callNumber);
  }
}

/// Preview-service fake: the caller decides what preview comes back for a
/// given set of slots/portions/items, independent of the real AI call.
class _FakePreviewService extends MealPlanPreviewService {
  _FakePreviewService(this._handler);

  final Future<MealPlanPreview> Function(List<MealSlot> mealSlots, int portionsPerMeal, List<DealItem> items)
  _handler;

  /// Every mealSlots list passed to previewMealPlan, in call order - lets
  /// tests assert a regenerate call only asked for the one slot it targets.
  final List<List<MealSlot>> calls = [];

  /// Every alreadyUsedAnchors list passed to previewMealPlan, in call order -
  /// lets tests assert a regenerate call told the AI which anchors the other
  /// slots already claimed.
  final List<List<AnchorItem>> usedAnchorsCalls = [];

  /// Every portionsPerMeal/dietaryNotes passed to previewMealPlan, in call
  /// order - lets tests assert the structure step's edits actually reached
  /// the generation call, not just the meal slots.
  final List<int> portionsPerMealCalls = [];
  final List<String> dietaryNotesCalls = [];

  @override
  Future<MealPlanPreview> previewMealPlan({
    required String apiKey,
    required List<MealSlot> mealSlots,
    required int portionsPerMeal,
    required List<DealItem> items,
    List<AnchorItem> alreadyUsedAnchors = const [],
    List<RecentHistoryItem> recentlyUsed = const [],
    String dietaryNotes = '',
    String? model,
  }) {
    calls.add(mealSlots);
    usedAnchorsCalls.add(alreadyUsedAnchors);
    portionsPerMealCalls.add(portionsPerMeal);
    dietaryNotesCalls.add(dietaryNotes);
    return _handler(mealSlots, portionsPerMeal, items);
  }
}

/// Preview-service fake whose calls never resolve on their own - each call
/// gets its own Completer, exposed in call order, so a test can hold a
/// specific call pending (e.g. to inspect a loading spinner) before
/// completing it explicitly.
class _FakeDeferredPreviewService extends MealPlanPreviewService {
  final List<Completer<MealPlanPreview>> completers = [];

  @override
  Future<MealPlanPreview> previewMealPlan({
    required String apiKey,
    required List<MealSlot> mealSlots,
    required int portionsPerMeal,
    required List<DealItem> items,
    List<AnchorItem> alreadyUsedAnchors = const [],
    List<RecentHistoryItem> recentlyUsed = const [],
    String dietaryNotes = '',
    String? model,
  }) {
    final completer = Completer<MealPlanPreview>();
    completers.add(completer);
    return completer.future;
  }
}

/// Preview-service fake for exercising the model-fallback/rate-limit flow on
/// the preview call: the caller decides what happens per model.
class _FakeModelAwarePreviewService extends MealPlanPreviewService {
  _FakeModelAwarePreviewService(this._byModel);

  final Future<MealPlanPreview> Function(String model) _byModel;

  @override
  Future<MealPlanPreview> previewMealPlan({
    required String apiKey,
    required List<MealSlot> mealSlots,
    required int portionsPerMeal,
    required List<DealItem> items,
    List<AnchorItem> alreadyUsedAnchors = const [],
    List<RecentHistoryItem> recentlyUsed = const [],
    String dietaryNotes = '',
    String? model,
  }) {
    return _byModel(model!);
  }
}

/// Generation-service fake: the caller decides what full plan comes back for
/// a given set of confirmed preview slots/items, independent of the real AI
/// call.
class _FakeGenerationService extends MealPlanGenerationService {
  _FakeGenerationService(this._handler);

  final Future<MealPlanFull> Function(List<MealSlotPreview> slots, List<DealItem> items) _handler;

  @override
  Future<MealPlanFull> generateMealPlan({
    required String apiKey,
    required List<MealSlotPreview> slots,
    required List<DealItem> items,
    String dietaryNotes = '',
    String? model,
    List<String>? groundingModels,
  }) {
    return _handler(slots, items);
  }
}

/// Generation-service fake for exercising the model-fallback/rate-limit flow
/// on the full-plan generation call: the caller decides what happens per
/// model.
class _FakeModelAwareGenerationService extends MealPlanGenerationService {
  _FakeModelAwareGenerationService(this._byModel);

  final Future<MealPlanFull> Function(String model) _byModel;

  @override
  Future<MealPlanFull> generateMealPlan({
    required String apiKey,
    required List<MealSlotPreview> slots,
    required List<DealItem> items,
    String dietaryNotes = '',
    String? model,
    List<String>? groundingModels,
  }) {
    return _byModel(model!);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('falls back to default scraper/extraction/config services when none are provided', (tester) async {
    final repository = StoreConfigRepository();
    await tester.pumpWidget(MaterialApp(home: PlanifScreen(repository: repository)));
    await tester.pumpAndSettle();

    // Never taps "Fetch deals" - just confirms the widget builds fine off
    // its own default-constructed services, without a fake standing in.
    expect(find.textContaining('Press "Fetch'), findsOneWidget);
  });

  testWidgets('steps forward to browse once deals are fetched, and back to fetch on demand', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Poulet',
          price: '3.99\$',
          unit: '',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // On the fetch step, there's nothing to step back from.
    expect(find.byTooltip('Back to fetch deals'), findsNothing);

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    // A completed fetch lands on the browse step automatically - the deal
    // is visible, and the fetch step's own button is off screen.
    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Fetch deals'), findsNothing);
    expect(find.byTooltip('Back to fetch deals'), findsOneWidget);

    // Stepping back returns to the fetch step - browsing controls are gone,
    // and "Fetch deals" is there to reload with.
    await tester.tap(find.byTooltip('Back to fetch deals'));
    await tester.pumpAndSettle();

    expect(find.text('Poulet'), findsNothing);
    expect(find.text('Fetch deals'), findsOneWidget);
    expect(find.byTooltip('Back to fetch deals'), findsNothing);
  });

  testWidgets('groups results into category sections with a cover-page marker', (tester) async {
    // Tall enough that every section/row is mounted without needing to
    // scroll - find.* only sees widgets that are actually built.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = StoreConfigRepository();
    await repository.save(const [
      StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga'),
      StoreConfig(id: 'metro', name: 'Metro', flyerUrl: 'https://example.com/metro'),
    ]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'irrelevant - extraction is faked')],
    });

    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Poulet rôti',
          price: '3.99\$',
          unit: '',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
        DealItem(
          name: 'Brocoli frais',
          price: '2.49\$',
          unit: 'lb',
          category: DealCategory.vegetables,
          storeName: 'IGA',
          pageIndex: 2,
        ),
        DealItem(
          name: 'Pain baguette',
          price: '1.99\$',
          unit: '',
          category: DealCategory.carbs,
          storeName: 'IGA',
          pageIndex: 2,
        ),
        DealItem(
          name: 'Papier essuie-tout',
          price: '4.99\$',
          unit: '',
          category: DealCategory.uncategorized,
          storeName: 'IGA',
          pageIndex: 2,
        ),
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Press "Fetch'), findsOneWidget);

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    // Once loaded, the per-store status collapses to a compact summary
    // chip per store instead of a full status row each.
    expect(find.text('IGA · 4'), findsOneWidget);
    expect(find.text('Metro · failed, tap to retry'), findsOneWidget);

    expect(find.text('Protein'), findsOneWidget);
    expect(find.text('Vegetables'), findsOneWidget);
    expect(find.text('Carbs'), findsOneWidget);
    expect(find.text('Uncategorized'), findsOneWidget);

    expect(find.text('Poulet rôti'), findsOneWidget);
    expect(find.text('Brocoli frais'), findsOneWidget);
    expect(find.text('Pain baguette'), findsOneWidget);
    expect(find.text('Papier essuie-tout'), findsOneWidget);

    expect(find.text('COVER'), findsOneWidget);
    expect(find.text('2.49\$/lb'), findsOneWidget);

    // The filter sheet's category filter covers every category present,
    // including uncategorized - not just the three named ones.
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'Uncategorized'), findsOneWidget);
  });

  testWidgets(
    'tapping an item cycles its preference, updates the summary, and survives reopening the screen from cache',
    (tester) async {
      final repository = StoreConfigRepository();
      await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

      final aiConfigRepo = AiConfigRepository();
      await aiConfigRepo.saveApiKey('sk-test');

      final scraper = _FakePagesScraper({
        'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
      });
      final extraction = _FakeExtractionService({
        'IGA': () async => const [
          DealItem(
            name: 'Poulet',
            price: '3.99\$',
            unit: '',
            category: DealCategory.protein,
            storeName: 'IGA',
            pageIndex: 2,
          ),
        ],
      });
      final preferenceRepository = DealPreferenceRepository();

      Future<void> pumpScreen() => tester.pumpWidget(
        MaterialApp(
          home: PlanifScreen(
            repository: repository,
            scraperService: scraper,
            extractionService: extraction,
            aiConfigRepository: aiConfigRepo,
            preferenceRepository: preferenceRepository,
          ),
        ),
      );

      await pumpScreen();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fetch deals'));
      await tester.pumpAndSettle();

      // The priority/excluded summary is always visible in the app bar -
      // no need to open the filter sheet to see it.
      expect(find.text('0 priority, 0 excluded'), findsOneWidget);

      // neutral -> priority
      await tester.tap(find.text('Poulet'));
      await tester.pumpAndSettle();
      expect(find.text('1 priority, 0 excluded'), findsOneWidget);
      expect(find.byIcon(Icons.star), findsOneWidget);

      // priority -> excluded
      await tester.tap(find.text('Poulet'));
      await tester.pumpAndSettle();
      expect(find.text('0 priority, 1 excluded'), findsOneWidget);
      expect(find.byIcon(Icons.star), findsNothing);

      expect(await preferenceRepository.loadAll(), {'IGA::Poulet::3.99\$::': DealPreference.excluded});

      // Reopening the screen (a fresh State, as if the app were relaunched)
      // shows the cached items straight away, with the persisted exclusion
      // still applied - no "Fetch deals" tap needed. Pumping an unrelated
      // widget first fully unmounts PlanifScreen so the next pumpScreen()
      // creates a brand new State (and re-runs initState) instead of
      // Flutter's element diffing reusing the existing one in place.
      await tester.pumpWidget(Container());
      await pumpScreen();
      await tester.pumpAndSettle();
      expect(find.text('Poulet'), findsOneWidget);
      expect(find.text('0 priority, 1 excluded'), findsOneWidget);

      // Explicitly reloading (stepping back to the fetch step, then tapping
      // "Fetch deals" again) is a deliberate reset: it clears the persisted
      // priority/excluded selections rather than re-applying them to the
      // freshly fetched items.
      await tester.tap(find.byTooltip('Back to fetch deals'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fetch deals'));
      await tester.pumpAndSettle();
      expect(find.text('0 priority, 0 excluded'), findsOneWidget);
      expect(await preferenceRepository.loadAll(), isEmpty);
    },
  );

  testWidgets(
    'shows a reminder instead of silently doing nothing when previewing cached items with no API key set',
    (tester) async {
      final repository = StoreConfigRepository();
      await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

      // No API key saved this time - the cache was populated by an earlier
      // session/browser profile that did have one configured.
      final cacheRepository = DealCacheRepository();
      await cacheRepository.save(const [
        DealItem(
          name: 'Poulet',
          price: '3.99\$',
          unit: '',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: PlanifScreen(repository: repository, cacheRepository: cacheRepository),
        ),
      );
      await tester.pumpAndSettle();

      // The cached item shows up immediately, with Step 2's preview button,
      // even though no API key is configured for this session.
      expect(find.text('Poulet'), findsOneWidget);
      expect(find.text('Preview meal plan'), findsOneWidget);

      await tester.tap(find.text('Preview meal plan'));
      await tester.pumpAndSettle();

      expect(find.text('Set your Google AI API key in Config first.'), findsOneWidget);
    },
  );

  testWidgets('shows resolved and failed rows in the full list while another store is still fetching', (
    tester,
  ) async {
    final repository = StoreConfigRepository();
    await repository.save(const [
      StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga'),
      StoreConfig(id: 'metro', name: 'Metro', flyerUrl: 'https://example.com/metro'),
      StoreConfig(id: 'maxi', name: 'Maxi', flyerUrl: 'https://example.com/maxi'),
    ]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
      'metro': const [FlyerPage(pageNumber: 1, altText: 'x')],
      'maxi': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });

    // A Completer that never resolves on its own lets the test hold Maxi's
    // extraction call open indefinitely, so _hasRun stays false and the
    // full per-store list (not the collapsed summary) stays on screen
    // while IGA and Metro have already settled to done/failed -
    // deterministically, with no race against how fast the fakes finish.
    final maxiCompleter = Completer<List<DealItem>>();
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Poulet',
          price: '3.99\$',
          unit: '',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
      'Metro': () async => throw Exception('HTTP 500'),
      'Maxi': () => maxiCompleter.future,
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('1 items'), findsOneWidget);
    expect(find.text('HTTP 500'), findsOneWidget);
    expect(find.text('Fetching…'), findsWidgets);
    expect(find.text('IGA · 1'), findsNothing);

    maxiCompleter.complete(const [
      DealItem(
        name: 'Fromage',
        price: '6.99\$',
        unit: '',
        category: DealCategory.protein,
        storeName: 'Maxi',
        pageIndex: 1,
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('IGA · 1'), findsOneWidget);
    expect(find.text('Metro · failed, tap to retry'), findsOneWidget);
    expect(find.text('Maxi · 1'), findsOneWidget);
  });

  testWidgets('filters the results list down to a single retailer', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = StoreConfigRepository();
    await repository.save(const [
      StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga'),
      StoreConfig(id: 'maxi', name: 'Maxi', flyerUrl: 'https://example.com/maxi'),
    ]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
      'maxi': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });

    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Poulet',
          price: '3.99\$',
          unit: '',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
      'Maxi': () async => const [
        DealItem(
          name: 'Fromage',
          price: '6.99\$',
          unit: '',
          category: DealCategory.protein,
          storeName: 'Maxi',
          pageIndex: 1,
        ),
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Fromage'), findsOneWidget);

    // The store filter now lives in the filter sheet (opened via the app
    // bar's filter icon) instead of an always-on row.
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'IGA'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 50));
    await tester.pumpAndSettle();

    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Fromage'), findsNothing);

    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 50));
    await tester.pumpAndSettle();

    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Fromage'), findsOneWidget);
  });

  testWidgets('filters the results list down to a single category', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });

    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Poulet',
          price: '3.99\$',
          unit: '',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
        DealItem(
          name: 'Pain baguette',
          price: '1.99\$',
          unit: '',
          category: DealCategory.carbs,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Pain baguette'), findsOneWidget);

    // The category filter lives in the filter sheet, same as the store
    // filter - picking "Carbs" there narrows the list, it doesn't just
    // scroll to it.
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Carbs'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 50));
    await tester.pumpAndSettle();

    expect(find.text('Pain baguette'), findsOneWidget);
    expect(find.text('Poulet'), findsNothing);

    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 50));
    await tester.pumpAndSettle();

    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Pain baguette'), findsOneWidget);
  });

  testWidgets('does not show a filter row when only one retailer has results', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Poulet',
          price: '3.99\$',
          unit: '',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    // The store filter now lives in the filter sheet - open it to check
    // there's nothing to select from with only one retailer.
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('shows an empty state when nothing could be parsed', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({'IGA': () async => throw Exception('boom')});

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    expect(find.text('No items found.'), findsOneWidget);
  });

  testWidgets('shows a message and does not fetch when no API key is configured', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService(const {});

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: AiConfigRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    expect(find.text('Set your Google AI API key in Config first.'), findsOneWidget);
    expect(find.textContaining('Press "Fetch'), findsOneWidget);
  });

  testWidgets('prompts for the next model when still rate limited, and continues with it', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');
    await aiConfigRepo.saveModels(['model-a', 'model-b']);

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeModelAwareExtractionService((model, storeName) async {
      if (model == 'model-a') throw RateLimitedException(model);
      return [
        DealItem(
          name: 'Poulet',
          price: '3.99\$',
          unit: '',
          category: DealCategory.protein,
          storeName: storeName,
          pageIndex: 1,
        ),
      ];
    });

    String? promptedCurrent;
    String? promptedNext;
    var promptCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          rateLimitWait: Duration.zero,
          rateLimitPrompt: (context, {required currentModel, nextModel}) async {
            promptCalls++;
            promptedCurrent = currentModel;
            promptedNext = nextModel;
            return RateLimitChoice.nextModel;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    expect(promptCalls, 1);
    expect(promptedCurrent, 'model-a');
    expect(promptedNext, 'model-b');
    expect(find.text('Poulet'), findsOneWidget);
  });

  testWidgets('offers only retrySame when the last configured model is still rate limited', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');
    await aiConfigRepo.saveModels(['only-model']);

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });

    var attempts = 0;
    final extraction = _FakeModelAwareExtractionService((model, storeName) async {
      attempts++;
      if (attempts <= 2) throw RateLimitedException(model);
      return [
        DealItem(
          name: 'Poulet',
          price: '3.99\$',
          unit: '',
          category: DealCategory.protein,
          storeName: storeName,
          pageIndex: 1,
        ),
      ];
    });

    String? promptedCurrent;
    Object? promptedNext = 'not called';

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          rateLimitWait: Duration.zero,
          rateLimitPrompt: (context, {required currentModel, nextModel}) async {
            promptedCurrent = currentModel;
            promptedNext = nextModel;
            return RateLimitChoice.retrySame;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    expect(promptedCurrent, 'only-model');
    expect(promptedNext, isNull);
    expect(attempts, 3);
    expect(find.text('Poulet'), findsOneWidget);
  });

  testWidgets('retries a single failed store without re-fetching the others', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [
      StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga'),
      StoreConfig(id: 'metro', name: 'Metro', flyerUrl: 'https://example.com/metro'),
    ]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
      'metro': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });

    var igaAttempts = 0;
    final extraction = _FakeExtractionService({
      'IGA': () async {
        igaAttempts++;
        if (igaAttempts == 1) throw Exception('boom');
        return const [
          DealItem(
            name: 'Poulet',
            price: '3.99\$',
            unit: '',
            category: DealCategory.protein,
            storeName: 'IGA',
            pageIndex: 1,
          ),
        ];
      },
      'Metro': () async => const [
        DealItem(
          name: 'Fromage',
          price: '6.99\$',
          unit: '',
          category: DealCategory.protein,
          storeName: 'Metro',
          pageIndex: 1,
        ),
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    expect(find.text('IGA · failed, tap to retry'), findsOneWidget);
    expect(find.text('Metro · 1'), findsOneWidget);
    expect(find.text('Fromage'), findsOneWidget);
    expect(find.text('Poulet'), findsNothing);

    await tester.tap(find.text('IGA · failed, tap to retry'));
    await tester.pumpAndSettle();

    expect(igaAttempts, 2);
    expect(find.text('IGA · 1'), findsOneWidget);
    expect(find.text('Metro · 1'), findsOneWidget);
    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Fromage'), findsOneWidget);
  });

  testWidgets('shows a retrying chip, and disables Fetch deals on the fetch step, while a single store retries', (
    tester,
  ) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });

    var attempts = 0;
    final retryCompleter = Completer<List<DealItem>>();
    final extraction = _FakeExtractionService({
      'IGA': () async {
        attempts++;
        if (attempts == 1) throw Exception('boom');
        return retryCompleter.future;
      },
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    expect(find.text('IGA · failed, tap to retry'), findsOneWidget);

    await tester.tap(find.text('IGA · failed, tap to retry'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('IGA · retrying…'), findsOneWidget);

    // The retry is a browse-step action (retrying one already-fetched
    // store), so "Fetch deals" itself isn't on screen right now - it only
    // lives on the fetch step. Stepping back to that step while the retry
    // is still in flight should still show it disabled, since a second
    // concurrent fetch is guarded against regardless of which step exposes
    // the button.
    await tester.tap(find.byTooltip('Back to fetch deals'));
    await tester.pump();

    // "Fetching…" now shows twice: once as the still-in-progress IGA row's
    // status, once as the disabled Fetch deals button's own label.
    expect(find.text('Fetching…'), findsNWidgets(2));
    final fetchButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Fetching…'));
    expect(fetchButton.onPressed, isNull);

    retryCompleter.complete(const [
      DealItem(
        name: 'Poulet',
        price: '3.99\$',
        unit: '',
        category: DealCategory.protein,
        storeName: 'IGA',
        pageIndex: 1,
      ),
    ]);
    await tester.pumpAndSettle();

    // The retry finishing re-enables the fetch step's button - the guard
    // was only ever about a concurrent fetch, not about staying on this
    // step. (The retried item itself landing back in the browse step's
    // results is covered by "retries a single failed store without
    // re-fetching the others".)
    expect(find.text('Fetch deals'), findsOneWidget);
    expect(find.text('Fetching…'), findsNothing);
  });

  testWidgets('splits a store with more pages than maxPagesPerCall into multiple extraction calls', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final pageCount = AiDealExtractionService.maxPagesPerCall + 2;
    final scraper = _FakePagesScraper({
      'iga': List.generate(pageCount, (i) => FlyerPage(pageNumber: i + 1, altText: 'Item $i')),
    });

    final chunkSizes = <int>[];
    final extraction = _FakeChunkAwareExtractionService((pages, callNumber) async {
      chunkSizes.add(pages.length);
      return [
        DealItem(
          name: 'Item $callNumber',
          price: '1.00\$',
          unit: '',
          category: DealCategory.uncategorized,
          storeName: 'IGA',
          pageIndex: pages.first.pageNumber,
        ),
      ];
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    expect(chunkSizes, [AiDealExtractionService.maxPagesPerCall, 2]);
    expect(find.text('IGA · 2'), findsOneWidget);
  });

  testWidgets("keeps an earlier chunk's items when a later chunk fails outright", (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final pageCount = AiDealExtractionService.maxPagesPerCall + 2;
    final scraper = _FakePagesScraper({
      'iga': List.generate(pageCount, (i) => FlyerPage(pageNumber: i + 1, altText: 'Item $i')),
    });

    final extraction = _FakeChunkAwareExtractionService((pages, callNumber) async {
      if (callNumber == 1) {
        return [
          DealItem(
            name: 'Poulet',
            price: '3.99\$',
            unit: '',
            category: DealCategory.protein,
            storeName: 'IGA',
            pageIndex: pages.first.pageNumber,
          ),
        ];
      }
      throw Exception('boom');
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    // The whole store is still reported as failed (chunk 2 never completed)
    // but chunk 1's already-extracted item isn't thrown away, and the chip
    // says so rather than reading as if nothing came of it.
    expect(find.text('IGA · 1 kept, failed, tap to retry'), findsOneWidget);
    expect(find.text('Poulet'), findsOneWidget);
  });

  testWidgets('shows the partial item count on a failed row while another store is still fetching', (
    tester,
  ) async {
    final repository = StoreConfigRepository();
    await repository.save(const [
      StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga'),
      StoreConfig(id: 'maxi', name: 'Maxi', flyerUrl: 'https://example.com/maxi'),
    ]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final pageCount = AiDealExtractionService.maxPagesPerCall + 2;
    final scraper = _FakePagesScraper({
      'iga': List.generate(pageCount, (i) => FlyerPage(pageNumber: i + 1, altText: 'Item $i')),
      'maxi': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });

    // Holding Maxi open (same technique as the test above) keeps _hasRun
    // false, so the full per-store list (_buildStatusRow), not the
    // collapsed summary chips, is what's on screen once IGA fails.
    final maxiCompleter = Completer<List<DealItem>>();
    final extraction = _FakeMultiStoreChunkAwareExtractionService({
      'IGA': (pages, callNumber) async {
        if (callNumber == 1) {
          return [
            DealItem(
              name: 'Poulet',
              price: '3.99\$',
              unit: '',
              category: DealCategory.protein,
              storeName: 'IGA',
              pageIndex: pages.first.pageNumber,
            ),
          ];
        }
        throw Exception('boom');
      },
      'Maxi': (pages, callNumber) => maxiCompleter.future,
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('1 items kept, then failed: boom'), findsOneWidget);
  });

  testWidgets('does not resend an earlier chunk when a later chunk needs a rate-limit retry', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final pageCount = AiDealExtractionService.maxPagesPerCall + 2;
    final scraper = _FakePagesScraper({
      'iga': List.generate(pageCount, (i) => FlyerPage(pageNumber: i + 1, altText: 'Item $i')),
    });

    final chunkPageCounts = <int>[];
    final extraction = _FakeChunkAwareExtractionService((pages, callNumber) async {
      chunkPageCounts.add(pages.length);
      // Call 1 is chunk 1, and succeeds immediately. Call 2 is chunk 2's
      // first attempt, which is rate limited; call 3 is chunk 2's automatic
      // cooldown retry, which succeeds.
      if (callNumber == 2) throw RateLimitedException('model-a');
      return [
        DealItem(
          name: 'Item $callNumber',
          price: '1.00\$',
          unit: '',
          category: DealCategory.uncategorized,
          storeName: 'IGA',
          pageIndex: pages.first.pageNumber,
        ),
      ];
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          rateLimitWait: Duration.zero,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    // Chunk 1's page count (maxPagesPerCall) appears exactly once - it's
    // never resent just because chunk 2 needed a retry.
    expect(chunkPageCounts, [AiDealExtractionService.maxPagesPerCall, 2, 2]);
    expect(find.text('IGA · 2'), findsOneWidget);
  });

  testWidgets('carries a model switch forward to later chunks instead of re-trying a skipped model', (
    tester,
  ) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');
    await aiConfigRepo.saveModels(['model-a', 'model-b']);

    // Two equal chunks, so a second chunk actually happens.
    final pageCount = AiDealExtractionService.maxPagesPerCall * 2;
    final scraper = _FakePagesScraper({
      'iga': List.generate(pageCount, (i) => FlyerPage(pageNumber: i + 1, altText: 'Item $i')),
    });

    final modelAttempts = <String, int>{};
    var promptCalls = 0;
    final extraction = _FakeModelAwareExtractionService((model, storeName) async {
      modelAttempts[model] = (modelAttempts[model] ?? 0) + 1;
      // model-a is permanently rate limited; model-b always works.
      if (model == 'model-a') throw RateLimitedException(model);
      return [
        DealItem(
          name: 'Item ${modelAttempts[model]}',
          price: '1.00\$',
          unit: '',
          category: DealCategory.uncategorized,
          storeName: storeName,
          pageIndex: 1,
        ),
      ];
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          rateLimitWait: Duration.zero,
          rateLimitPrompt: (context, {required currentModel, nextModel}) async {
            promptCalls++;
            return RateLimitChoice.nextModel;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    // Chunk 1 hits model-a twice (initial + automatic cooldown retry) before
    // the user is asked once and switches to model-b. Chunk 2 should start
    // straight from model-b - if it forgot the switch and started over at
    // model-a, model-a would be attempted twice more and the user would be
    // asked a second time.
    expect(modelAttempts['model-a'], 2);
    expect(modelAttempts['model-b'], 2);
    expect(promptCalls, 1);
    expect(find.text('IGA · 2'), findsOneWidget);
  });

  testWidgets('resets the store filter when a retry drops the filtered store to zero items', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = StoreConfigRepository();
    await repository.save(const [
      StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga'),
      StoreConfig(id: 'metro', name: 'Metro', flyerUrl: 'https://example.com/metro'),
    ]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final pageCount = AiDealExtractionService.maxPagesPerCall + 2;
    final scraper = _FakePagesScraper({
      'iga': List.generate(pageCount, (i) => FlyerPage(pageNumber: i + 1, altText: 'Item $i')),
      'metro': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });

    final extraction = _FakeMultiStoreChunkAwareExtractionService({
      'IGA': (pages, callNumber) async {
        // Initial fetch: chunk 1 succeeds, chunk 2 fails outright, leaving
        // IGA with one partial item.
        if (callNumber == 1) {
          return [
            DealItem(
              name: 'Poulet',
              price: '3.99\$',
              unit: '',
              category: DealCategory.protein,
              storeName: 'IGA',
              pageIndex: pages.first.pageNumber,
            ),
          ];
        }
        if (callNumber == 2) throw Exception('boom');
        // Retry: both chunks now succeed, but with nothing to report.
        return const [];
      },
      'Metro': (pages, callNumber) async => [
        DealItem(
          name: 'Fromage',
          price: '6.99\$',
          unit: '',
          category: DealCategory.protein,
          storeName: 'Metro',
          pageIndex: pages.first.pageNumber,
        ),
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    // Both stores have items, so the filter sheet's store row has something
    // to select from.
    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Fromage'), findsOneWidget);

    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'IGA'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 50));
    await tester.pumpAndSettle();

    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Fromage'), findsNothing);

    await tester.tap(find.text('IGA · 1 kept, failed, tap to retry'));
    await tester.pumpAndSettle();

    // The retry left IGA with zero items, so filtering to "IGA" would show
    // nothing with no way back - the filter should have reset instead.
    expect(find.text('Fromage'), findsOneWidget);
  });

  testWidgets('resets the category filter when a retry drops the filtered category to zero items', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final pageCount = AiDealExtractionService.maxPagesPerCall + 2;
    final scraper = _FakePagesScraper({
      'iga': List.generate(pageCount, (i) => FlyerPage(pageNumber: i + 1, altText: 'Item $i')),
    });

    final extraction = _FakeChunkAwareExtractionService((pages, callNumber) async {
      // Initial fetch: chunk 1 returns both categories, chunk 2 fails
      // outright, leaving IGA "failed" with 2 items kept.
      if (callNumber == 1) {
        return [
          DealItem(
            name: 'Poulet',
            price: '3.99\$',
            unit: '',
            category: DealCategory.protein,
            storeName: 'IGA',
            pageIndex: pages.first.pageNumber,
          ),
          DealItem(
            name: 'Pain baguette',
            price: '1.99\$',
            unit: '',
            category: DealCategory.carbs,
            storeName: 'IGA',
            pageIndex: pages.first.pageNumber,
          ),
        ];
      }
      if (callNumber == 2) throw Exception('boom');
      // Retry: only the carbs item comes back this time.
      if (callNumber == 3) {
        return [
          DealItem(
            name: 'Pain baguette',
            price: '1.99\$',
            unit: '',
            category: DealCategory.carbs,
            storeName: 'IGA',
            pageIndex: pages.first.pageNumber,
          ),
        ];
      }
      return const [];
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Pain baguette'), findsOneWidget);

    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Protein'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 50));
    await tester.pumpAndSettle();

    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Pain baguette'), findsNothing);

    await tester.tap(find.text('IGA · 2 kept, failed, tap to retry'));
    await tester.pumpAndSettle();

    // The retry left IGA with no protein items, so filtering to "Protein"
    // would show nothing with no way back - the filter should have reset
    // instead, so the carbs item that came back is visible again.
    expect(find.text('Pain baguette'), findsOneWidget);
  });

  testWidgets('generates a meal plan preview, swaps an anchor item, then generates the full meal plan', (
    tester,
  ) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
        DealItem(
          name: 'Ground pork',
          price: '4.49\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );

    final generationService = _FakeGenerationService(
      (slots, items) async => MealPlanFull(
        slots: [
          MealSlotFull(
            mealType: slots.single.mealType,
            protein: slots.single.protein,
            count: slots.single.count,
            portionsPerMeal: slots.single.portionsPerMeal,
            proteinComponent: const MealComponent(
              type: MealComponentType.link,
              name: 'Slow-roasted pulled pork',
              recipeUrl: 'https://example.com/pulled-pork',
              usesWeeklyDeal: true,
              dealItems: [AnchorItem(name: 'Ground pork', store: 'IGA')],
            ),
            carbComponent: const MealComponent(
              type: MealComponentType.coveredByProtein,
              name: 'Buns (included in the pulled pork recipe)',
              recipeUrl: 'https://example.com/pulled-pork',
              usesWeeklyDeal: false,
            ),
            vegetableComponent: const MealComponent(
              type: MealComponentType.simpleSide,
              name: 'Steamed green beans',
              note: 'Steam 5 min, toss with butter.',
              usesWeeklyDeal: false,
            ),
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
          generationService: generationService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    expect(find.text('Preview meal plan'), findsOneWidget);

    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    expect(find.text('Lunch · meat'), findsOneWidget);
    expect(find.text('15 portions'), findsOneWidget);
    // Exact chip text (name + store), not a loose substring match - the
    // picker tile above now also shows the bare anchor name on its own
    // before a recipe exists, so "contains" would be ambiguous between the
    // tile and the chip.
    expect(find.text('Chicken thighs · IGA'), findsOneWidget);
    expect(find.text('Big-batch chicken thigh stir-fry.'), findsOneWidget);
    expect(find.text('Generate recipe'), findsOneWidget);

    // Swap the anchor item for another available deal item.
    await tester.tap(find.text('Chicken thighs · IGA'));
    await tester.pumpAndSettle();
    expect(find.text('Swap anchor item'), findsOneWidget);

    await tester.tap(find.text('Ground pork'));
    await tester.pumpAndSettle();

    expect(find.text('Ground pork · IGA'), findsOneWidget);
    expect(find.textContaining('Chicken thighs'), findsNothing);

    await tester.tap(find.text('Generate recipe'));
    await tester.pumpAndSettle();

    // The recipe renders right on the same card as the anchors, and this
    // is the only (and therefore last) slot, so the bar's now offering to
    // save instead of moving to a next meal. The picker tile above the
    // card summarizes protein/carb/veg by their bare deal-item name (e.g.
    // "Ground pork"), not the recipe's own dish name, so the dish name
    // itself still shows just once, on the card.
    expect(find.text('Slow-roasted pulled pork'), findsOneWidget);
    expect(find.text('https://example.com/pulled-pork'), findsOneWidget);
    expect(find.text("This week's deal"), findsOneWidget);
    // Once for the anchor chip up top, once for the recipe's own deal-item
    // badge below - the picker tile shows the bare name without the store,
    // so it doesn't add a third.
    expect(find.text('Ground pork · IGA'), findsNWidgets(2));
    expect(find.text('This recipe already includes the carb — see above.'), findsOneWidget);
    // The vegetable side has no deal item of its own, so the tile falls
    // back to the same name the card shows - hence twice here.
    expect(find.text('Steamed green beans'), findsNWidgets(2));
    expect(find.text('Steam 5 min, toss with butter.'), findsOneWidget);
    expect(find.text("Save this week's plan"), findsOneWidget);

    // The view switcher (now a compact icon toggle in the app bar) still
    // gets back to the deal items without losing the generated recipe.
    await tester.tap(find.byTooltip('Deal items'));
    await tester.pumpAndSettle();
    expect(find.text('Ground pork'), findsOneWidget);

    await tester.tap(find.byTooltip('Meal plan'));
    await tester.pumpAndSettle();
    expect(find.text('Slow-roasted pulled pork'), findsOneWidget);
  });

  testWidgets('saves the full plan to history as this week\'s entry, overwriting on a second save', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );

    final generationService = _FakeGenerationService(
      (slots, items) async => MealPlanFull(
        slots: [
          MealSlotFull(
            mealType: slots.single.mealType,
            protein: slots.single.protein,
            count: slots.single.count,
            portionsPerMeal: slots.single.portionsPerMeal,
            proteinComponent: const MealComponent(
              type: MealComponentType.link,
              name: 'General Tao Chicken',
              usesWeeklyDeal: true,
              dealItems: [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            ),
            carbComponent: const MealComponent(type: MealComponentType.simpleSide, name: 'Rice', usesWeeklyDeal: false),
            vegetableComponent: const MealComponent(
              type: MealComponentType.simpleSide,
              name: 'Broccoli',
              usesWeeklyDeal: false,
            ),
          ),
        ],
      ),
    );

    final mealHistoryRepository = MealHistoryRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
          generationService: generationService,
          mealHistoryRepository: mealHistoryRepository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate recipe'));
    await tester.pumpAndSettle();

    expect(find.text('Save this week\'s plan'), findsOneWidget);
    await tester.tap(find.text('Save this week\'s plan'));
    await tester.pumpAndSettle();

    expect(find.text('Saved this week\'s plan to history.'), findsOneWidget);
    final saved = await mealHistoryRepository.loadAll();
    expect(saved.length, 1);
    expect(saved.single.slots.single.recipeName, 'General Tao Chicken');

    // Saving again for the same week overwrites rather than adding a second
    // entry - simulated here by writing directly with the same weekId a
    // regenerated plan would also resolve to (isoWeekId of "now").
    await tester.tap(find.text('Save this week\'s plan'));
    await tester.pumpAndSettle();

    final savedAgain = await mealHistoryRepository.loadAll();
    expect(savedAgain.length, 1);
  });

  testWidgets('extracts and shows the ingredient list from the full plan', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );

    final generationService = _FakeGenerationService(
      (slots, items) async => MealPlanFull(
        slots: [
          MealSlotFull(
            mealType: slots.single.mealType,
            protein: slots.single.protein,
            count: slots.single.count,
            portionsPerMeal: slots.single.portionsPerMeal,
            proteinComponent: const MealComponent(
              type: MealComponentType.aiRecipe,
              name: 'Chicken stir-fry',
              ingredients: [Ingredient(name: 'Chicken thighs', amount: '1.5 kg')],
              usesWeeklyDeal: true,
              dealItems: [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            ),
            carbComponent: const MealComponent(type: MealComponentType.coveredByProtein, name: 'Rice', usesWeeklyDeal: false),
            vegetableComponent: const MealComponent(
              type: MealComponentType.simpleSide,
              name: 'Broccoli',
              usesWeeklyDeal: false,
            ),
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
          generationService: generationService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate recipe'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Extract ingredient list'));
    await tester.pumpAndSettle();

    expect(find.text('Ingredient list'), findsOneWidget);
    expect(find.text('Chicken thighs — 1.5 kg'), findsOneWidget);
    // "Broccoli" also still shows in the (now-covered) picker tile and
    // review card behind the dialog, so it appears three times: tile,
    // card, and the extracted list.
    expect(find.text('Broccoli'), findsNWidgets(3));
    // The carb component is covered_by_protein, so it isn't listed
    // separately in the shopping list, and the underlying card still
    // doesn't render it by name - but the picker tile does, naming the
    // actual ingredient rather than just pointing back at the protein.
    expect(find.text('Rice'), findsOneWidget);
  });

  testWidgets('shows an error snackbar and re-enables the button when full-plan generation fails', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );
    final generationService = _FakeGenerationService((slots, items) async => throw Exception('AI API HTTP 500'));

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
          generationService: generationService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Generate recipe'));
    await tester.pumpAndSettle();

    expect(find.text('Could not generate this recipe: AI API HTTP 500'), findsOneWidget);
    expect(find.text('Generate recipe'), findsOneWidget);
  });

  testWidgets('prompts for the next model when the full-plan generation call is still rate limited, and continues with it', (
    tester,
  ) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');
    await aiConfigRepo.saveModels(['model-a', 'model-b']);

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );

    final generationService = _FakeModelAwareGenerationService((model) async {
      if (model == 'model-a') throw RateLimitedException(model);
      return const MealPlanFull(
        slots: [
          MealSlotFull(
            mealType: MealType.lunch,
            protein: 'meat',
            count: 5,
            portionsPerMeal: 3,
            proteinComponent: MealComponent(
              type: MealComponentType.simpleSide,
              name: 'Roast chicken thighs',
              note: 'Roast at 425F for 35 min.',
              usesWeeklyDeal: true,
              dealItems: [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            ),
            carbComponent: MealComponent(type: MealComponentType.simpleSide, name: 'Rice', usesWeeklyDeal: false),
            vegetableComponent: MealComponent(
              type: MealComponentType.simpleSide,
              name: 'Broccoli',
              usesWeeklyDeal: false,
            ),
          ),
        ],
      );
    });

    String? promptedCurrent;
    String? promptedNext;
    var promptCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
          generationService: generationService,
          rateLimitWait: Duration.zero,
          rateLimitPrompt: (context, {required currentModel, nextModel}) async {
            promptCalls++;
            promptedCurrent = currentModel;
            promptedNext = nextModel;
            return RateLimitChoice.nextModel;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate recipe'));
    await tester.pumpAndSettle();

    expect(promptCalls, 1);
    expect(promptedCurrent, 'model-a');
    expect(promptedNext, 'model-b');
    // The picker tile shows the underlying deal item ("Chicken thighs"),
    // not the recipe's own name for the dish, so this only shows once.
    expect(find.text('Roast chicken thighs'), findsOneWidget);
  });

  testWidgets('opens a recipe link via the injected launcher when tapped', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );
    final generationService = _FakeGenerationService(
      (slots, items) async => MealPlanFull(
        slots: [
          MealSlotFull(
            mealType: slots.single.mealType,
            protein: slots.single.protein,
            count: slots.single.count,
            portionsPerMeal: slots.single.portionsPerMeal,
            proteinComponent: const MealComponent(
              type: MealComponentType.link,
              name: 'Slow-roasted pulled pork',
              recipeUrl: 'https://example.com/pulled-pork',
              usesWeeklyDeal: false,
            ),
            carbComponent: const MealComponent(type: MealComponentType.simpleSide, name: 'Rice', usesWeeklyDeal: false),
            vegetableComponent: const MealComponent(
              type: MealComponentType.simpleSide,
              name: 'Broccoli',
              usesWeeklyDeal: false,
            ),
          ),
        ],
      ),
    );

    final openedUris = <Uri>[];

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
          generationService: generationService,
          launchRecipeLink: (uri) async => openedUris.add(uri),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate recipe'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('https://example.com/pulled-pork'));
    await tester.pumpAndSettle();

    expect(openedUris, [Uri.parse('https://example.com/pulled-pork')]);
  });

  testWidgets('shows ingredients and numbered steps for an ai_recipe component', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );
    final generationService = _FakeGenerationService(
      (slots, items) async => MealPlanFull(
        slots: [
          MealSlotFull(
            mealType: slots.single.mealType,
            protein: slots.single.protein,
            count: slots.single.count,
            portionsPerMeal: slots.single.portionsPerMeal,
            proteinComponent: const MealComponent(
              type: MealComponentType.aiRecipe,
              name: 'Big-batch chicken thigh curry',
              ingredients: [Ingredient(name: 'chicken thighs', amount: '1.5 kg')],
              instructions: ['Sear the chicken.', 'Simmer in curry sauce for 20 min.'],
              usesWeeklyDeal: true,
              dealItems: [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            ),
            carbComponent: const MealComponent(type: MealComponentType.simpleSide, name: 'Rice', usesWeeklyDeal: false),
            vegetableComponent: const MealComponent(
              type: MealComponentType.simpleSide,
              name: 'Broccoli',
              usesWeeklyDeal: false,
            ),
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
          generationService: generationService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate recipe'));
    await tester.pumpAndSettle();

    expect(find.text('AI recipe'), findsOneWidget);
    expect(find.text('Ingredients'), findsOneWidget);
    expect(find.text('• chicken thighs — 1.5 kg'), findsOneWidget);
    expect(find.text('Steps'), findsOneWidget);
    expect(find.text('1. Sear the chicken.'), findsOneWidget);
    expect(find.text('2. Simmer in curry sauce for 20 min.'), findsOneWidget);
  });

  testWidgets('regenerates a single slot in the full plan without affecting other slots', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [
          MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5),
          MealSlot(id: 'supper-tofu', mealType: MealType.supper, protein: 'tofu', count: 4),
        ],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
        DealItem(
          name: 'Tofu',
          price: '2.29\$',
          unit: '',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: MealType.lunch,
            protein: 'meat',
            count: 5,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Lunch note.',
          ),
          MealSlotPreview(
            mealType: MealType.supper,
            protein: 'tofu',
            count: 4,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Tofu', store: 'IGA')],
            note: 'Supper note.',
          ),
        ],
      ),
    );

    // Every generation call is now for exactly one slot - the review step
    // only ever asks for the meal it's currently showing. A second call for
    // the same meal type is a regenerate, so the fake tells them apart by
    // call order per meal type rather than by how many slots were asked for
    // at once.
    final lunchCalls = <List<MealSlotPreview>>[];
    final supperCalls = <List<MealSlotPreview>>[];
    final generationService = _FakeGenerationService((slots, items) async {
      final slot = slots.single;
      if (slot.mealType == MealType.lunch) {
        lunchCalls.add(slots);
        final name = lunchCalls.length == 1 ? 'Original lunch recipe' : 'Regenerated lunch recipe';
        return MealPlanFull(
          slots: [
            MealSlotFull(
              mealType: slot.mealType,
              protein: slot.protein,
              count: slot.count,
              portionsPerMeal: slot.portionsPerMeal,
              proteinComponent: MealComponent(type: MealComponentType.simpleSide, name: name, usesWeeklyDeal: false),
              carbComponent: const MealComponent(type: MealComponentType.simpleSide, name: 'Rice', usesWeeklyDeal: false),
              vegetableComponent: const MealComponent(
                type: MealComponentType.simpleSide,
                name: 'Broccoli',
                usesWeeklyDeal: false,
              ),
            ),
          ],
        );
      }
      supperCalls.add(slots);
      return MealPlanFull(
        slots: [
          MealSlotFull(
            mealType: slot.mealType,
            protein: slot.protein,
            count: slot.count,
            portionsPerMeal: slot.portionsPerMeal,
            proteinComponent: const MealComponent(
              type: MealComponentType.simpleSide,
              name: 'Original supper recipe',
              usesWeeklyDeal: false,
            ),
            carbComponent: const MealComponent(type: MealComponentType.simpleSide, name: 'Quinoa', usesWeeklyDeal: false),
            vegetableComponent: const MealComponent(
              type: MealComponentType.simpleSide,
              name: 'Green beans',
              usesWeeklyDeal: false,
            ),
          ),
        ],
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
          generationService: generationService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    // Lunch is the first meal on the review step.
    expect(find.text('Lunch · meat'), findsOneWidget);
    await tester.tap(find.text('Generate recipe'));
    await tester.pumpAndSettle();

    // Shows once in the picker tile's ingredient summary, once in the card.
    expect(find.text('Original lunch recipe'), findsNWidgets(2));
    expect(lunchCalls.length, 1);
    expect(supperCalls, isEmpty);

    // Move on to the supper meal (via its picker tile) and generate its
    // recipe too.
    await tester.tap(find.byKey(const ValueKey('review-step-1')));
    await tester.pumpAndSettle();
    expect(find.text('Supper · tofu'), findsOneWidget);
    await tester.tap(find.text('Generate recipe'));
    await tester.pumpAndSettle();

    expect(find.text('Original supper recipe'), findsNWidgets(2));
    expect(supperCalls.length, 1);

    // Step back to the lunch meal (via its tile) and regenerate just its
    // recipe - the supper meal (not on screen) is untouched. Both tiles
    // keep summarizing their own recipe regardless of which one is open.
    await tester.tap(find.byKey(const ValueKey('review-step-0')));
    await tester.pumpAndSettle();
    expect(find.text('Lunch · meat'), findsOneWidget);
    expect(find.text('Original lunch recipe'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Regenerate this recipe'));
    await tester.pumpAndSettle();

    expect(lunchCalls.length, 2);
    expect(lunchCalls[1].single.mealType, MealType.lunch);
    expect(find.text('Regenerated lunch recipe'), findsNWidgets(2));
    expect(find.text('Original lunch recipe'), findsNothing);
    expect(supperCalls.length, 1);

    await tester.tap(find.byKey(const ValueKey('review-step-1')));
    await tester.pumpAndSettle();
    expect(find.text('Original supper recipe'), findsNWidgets(2));
  });

  testWidgets('shows an error snackbar and re-enables the button when a full-plan slot regeneration fails', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );

    var generationCallCount = 0;
    final generationService = _FakeGenerationService((slots, items) async {
      generationCallCount++;
      if (generationCallCount == 1) {
        final slot = slots.single;
        return MealPlanFull(
          slots: [
            MealSlotFull(
              mealType: slot.mealType,
              protein: slot.protein,
              count: slot.count,
              portionsPerMeal: slot.portionsPerMeal,
              proteinComponent: const MealComponent(
                type: MealComponentType.simpleSide,
                name: 'Original recipe',
                usesWeeklyDeal: false,
              ),
              carbComponent: const MealComponent(type: MealComponentType.simpleSide, name: 'Rice', usesWeeklyDeal: false),
              vegetableComponent: const MealComponent(
                type: MealComponentType.simpleSide,
                name: 'Broccoli',
                usesWeeklyDeal: false,
              ),
            ),
          ],
        );
      }
      throw Exception('AI API HTTP 500');
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
          generationService: generationService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate recipe'));
    await tester.pumpAndSettle();

    expect(find.text('Original recipe'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Regenerate this recipe'));
    await tester.pumpAndSettle();

    expect(find.text('Could not generate this recipe: AI API HTTP 500'), findsOneWidget);
    // The failed regeneration left the existing recipe in place, and the
    // button is re-enabled rather than stuck showing its spinner. Shows
    // once in the picker tile's summary, once in the card.
    expect(find.text('Original recipe'), findsNWidgets(2));
    expect(
      tester
          .widget<IconButton>(find.ancestor(of: find.byTooltip('Regenerate this recipe'), matching: find.byType(IconButton)))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'prompts for the next model when a full-plan slot regeneration call is still rate limited, and continues with it',
    (tester) async {
      final repository = StoreConfigRepository();
      await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

      final aiConfigRepo = AiConfigRepository();
      await aiConfigRepo.saveApiKey('sk-test');
      await aiConfigRepo.saveModels(['model-a', 'model-b']);

      final mealPlanConfigRepository = MealPlanConfigRepository();
      await mealPlanConfigRepository.save(
        const MealPlanConfig(
          portionsPerMeal: 3,
          diversityWindowDays: 28,
          mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
        ),
      );

      final scraper = _FakePagesScraper({
        'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
      });
      final extraction = _FakeExtractionService({
        'IGA': () async => const [
          DealItem(
            name: 'Chicken thighs',
            price: '3.99\$',
            unit: 'lb',
            category: DealCategory.protein,
            storeName: 'IGA',
            pageIndex: 1,
          ),
        ],
      });

      final previewService = _FakePreviewService(
        (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
          slots: [
            MealSlotPreview(
              mealType: mealSlots.single.mealType,
              protein: mealSlots.single.protein,
              count: mealSlots.single.count,
              portionsPerMeal: portionsPerMeal,
              anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
              note: 'Big-batch chicken thigh stir-fry.',
            ),
          ],
        ),
      );

      final generationService = _FakeModelAwareGenerationService((model) async {
        if (model == 'model-a') throw RateLimitedException(model);
        return const MealPlanFull(
          slots: [
            MealSlotFull(
              mealType: MealType.lunch,
              protein: 'meat',
              count: 5,
              portionsPerMeal: 3,
              proteinComponent: MealComponent(
                type: MealComponentType.simpleSide,
                name: 'Roast chicken thighs',
                usesWeeklyDeal: false,
              ),
              carbComponent: MealComponent(type: MealComponentType.simpleSide, name: 'Rice', usesWeeklyDeal: false),
              vegetableComponent: MealComponent(
                type: MealComponentType.simpleSide,
                name: 'Broccoli',
                usesWeeklyDeal: false,
              ),
            ),
          ],
        );
      });

      var promptCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: PlanifScreen(
            repository: repository,
            scraperService: scraper,
            extractionService: extraction,
            aiConfigRepository: aiConfigRepo,
            mealPlanConfigRepository: mealPlanConfigRepository,
            previewService: previewService,
            generationService: generationService,
            rateLimitWait: Duration.zero,
            rateLimitPrompt: (context, {required currentModel, nextModel}) async {
              promptCalls++;
              return RateLimitChoice.nextModel;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Fetch deals'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview meal plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Looks good, generate preview →'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate recipe'));
      await tester.pumpAndSettle();

      // Generating the initial recipe already used up one rate-limit
      // fallback (model-a -> model-b). Shows once in the picker tile's
      // summary, once in the card.
      expect(promptCalls, 1);
      expect(find.text('Roast chicken thighs'), findsNWidgets(2));

      await tester.tap(find.byTooltip('Regenerate this recipe'));
      await tester.pumpAndSettle();

      // Regenerating this slot falls back through model-a -> model-b again,
      // independently of the initial generation call.
      expect(promptCalls, 2);
      expect(find.text('Roast chicken thighs'), findsNWidgets(2));
    },
  );

  testWidgets('shows an error snackbar and re-enables the button when the preview call fails', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService((mealSlots, portionsPerMeal, items) async {
      throw Exception('boom');
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    expect(find.text('Could not generate preview: boom'), findsOneWidget);
    // Stays on the structure step (not silently kicked back to the deals
    // view) so the user doesn't have to reopen and re-confirm it - the
    // button falls back to its initial label instead of getting stuck
    // showing "Generating…".
    expect(find.text('Looks good, generate preview →'), findsOneWidget);
  });

  testWidgets('cancelling the anchor swap dialog leaves the anchor item unchanged', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
        DealItem(
          name: 'Ground pork',
          price: '4.49\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Chicken thighs · IGA'));
    await tester.pumpAndSettle();
    expect(find.text('Swap anchor item'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Chicken thighs · IGA'), findsOneWidget);
  });

  testWidgets('toggles between the deal items list and the meal plan preview', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    // Generating a preview switches straight into it.
    expect(find.text('Lunch · meat'), findsOneWidget);

    await tester.tap(find.byTooltip('Deal items'));
    await tester.pumpAndSettle();
    expect(find.text('Chicken thighs'), findsOneWidget);
    expect(find.text('Lunch · meat'), findsNothing);

    await tester.tap(find.byTooltip('Meal plan'));
    await tester.pumpAndSettle();
    expect(find.text('Lunch · meat'), findsOneWidget);
  });

  testWidgets('prompts for the next model when the preview call is still rate limited, and continues with it', (
    tester,
  ) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');
    await aiConfigRepo.saveModels(['model-a', 'model-b']);

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakeModelAwarePreviewService((model) async {
      if (model == 'model-a') throw RateLimitedException(model);
      return MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: MealType.lunch,
            protein: 'meat',
            count: 5,
            portionsPerMeal: 3,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      );
    });

    String? promptedCurrent;
    String? promptedNext;
    var promptCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
          rateLimitWait: Duration.zero,
          rateLimitPrompt: (context, {required currentModel, nextModel}) async {
            promptCalls++;
            promptedCurrent = currentModel;
            promptedNext = nextModel;
            return RateLimitChoice.nextModel;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    expect(promptCalls, 1);
    expect(promptedCurrent, 'model-a');
    expect(promptedNext, 'model-b');
    expect(find.text('Lunch · meat'), findsOneWidget);
  });

  testWidgets('regenerates a single slot without affecting the other slots', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [
          MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5),
          MealSlot(id: 'supper-tofu', mealType: MealType.supper, protein: 'tofu', count: 4),
        ],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
        DealItem(
          name: 'Ground pork',
          price: '4.49\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
        DealItem(
          name: 'Tofu',
          price: '2.29\$',
          unit: '',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService((mealSlots, portionsPerMeal, items) async {
      if (mealSlots.length == 2) {
        return MealPlanPreview(
          slots: [
            MealSlotPreview(
              mealType: MealType.lunch,
              protein: 'meat',
              count: 5,
              portionsPerMeal: portionsPerMeal,
              anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
              note: 'Original lunch note.',
            ),
            MealSlotPreview(
              mealType: MealType.supper,
              protein: 'tofu',
              count: 4,
              portionsPerMeal: portionsPerMeal,
              anchorItems: const [AnchorItem(name: 'Tofu', store: 'IGA')],
              note: 'Original supper note.',
            ),
          ],
        );
      }
      final slot = mealSlots.single;
      return MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: slot.mealType,
            protein: slot.protein,
            count: slot.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Ground pork', store: 'IGA')],
            note: 'Regenerated lunch note.',
          ),
        ],
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    // Only the current meal (lunch, first on the review step) is on screen
    // at a time - the supper slot's state still exists, it's just on a
    // different step.
    expect(find.text('Original lunch note.'), findsOneWidget);
    expect(find.text('Original supper note.'), findsNothing);
    expect(previewService.calls.length, 1);

    await tester.tap(find.byTooltip('Regenerate suggested items'));
    await tester.pumpAndSettle();

    expect(previewService.calls.length, 2);
    expect(previewService.calls[1].length, 1);
    expect(previewService.calls[1].single.mealType, MealType.lunch);
    // The regenerate call is told the supper slot's current anchor, so the
    // AI doesn't reuse an ingredient another slot is already using.
    expect(previewService.usedAnchorsCalls[1].map((a) => a.name), ['Tofu']);

    // The regenerated slot changed... The picker tile above now also
    // guesses at a protein/carb/veg breakdown from the anchors, so the new
    // anchor's bare name shows up there too, alongside the chip.
    expect(find.text('Regenerated lunch note.'), findsOneWidget);
    expect(find.text('Ground pork · IGA'), findsOneWidget);
    expect(find.textContaining('Chicken thighs'), findsNothing);

    // ...and stepping to the supper meal shows it's untouched. Its tile
    // has been showing "Tofu" (its protein-category anchor) the whole
    // time, independently of which meal's card is on screen; the chip
    // shows up alongside it once its card is selected.
    await tester.tap(find.byKey(const ValueKey('review-step-1')));
    await tester.pumpAndSettle();
    expect(find.text('Original supper note.'), findsOneWidget);
    expect(find.text('Tofu · IGA'), findsOneWidget);
  });

  testWidgets('adds an anchor item to a slot via the Add item chip', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
        DealItem(
          name: 'Ground pork',
          price: '4.49\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Ground pork'), findsNothing);

    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();
    expect(find.text('Add anchor item'), findsOneWidget);
    // Chicken thighs is already an anchor, so it should not be offered again.
    expect(find.widgetWithText(ListTile, 'Chicken thighs'), findsNothing);

    await tester.tap(find.text('Ground pork'));
    await tester.pumpAndSettle();

    // The picker tile's protein-summary row keeps showing Chicken thighs
    // (the first protein-category anchor), so its chip is checked by exact
    // text to avoid also matching the tile.
    expect(find.text('Chicken thighs · IGA'), findsOneWidget);
    expect(find.textContaining('Ground pork'), findsOneWidget);
  });

  testWidgets('removes an anchor item from a slot via its chip delete icon', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    // Exact chip text - the picker tile above shows the same anchor's bare
    // name in its own protein-summary row.
    expect(find.text('Chicken thighs · IGA'), findsOneWidget);

    final chip = find.widgetWithText(InputChip, 'Chicken thighs · IGA');
    final deleteIcon = find.descendant(of: chip, matching: find.byIcon(Icons.close));
    await tester.tap(deleteIcon);
    await tester.pumpAndSettle();

    expect(find.textContaining('Chicken thighs'), findsNothing);
    expect(find.text('Add item'), findsOneWidget);
  });

  testWidgets('shows a spinner on the card while a slot regenerate call is pending', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakeDeferredPreviewService();

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();

    // Resolve the initial generate call (previewService.completers[0]) to
    // get the preview on screen before exercising the regenerate button
    // with its own, independently-controlled call.
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    previewService.completers[0].complete(
      MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: MealType.lunch,
            protein: 'meat',
            count: 5,
            portionsPerMeal: 3,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Lunch · meat'), findsOneWidget);

    final lunchCard = find.ancestor(of: find.text('Lunch · meat'), matching: find.byType(Card));
    final regenerateButton = find.descendant(of: lunchCard, matching: find.byIcon(Icons.refresh));
    await tester.tap(regenerateButton);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.descendant(of: lunchCard, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    expect(find.descendant(of: lunchCard, matching: find.byIcon(Icons.refresh)), findsNothing);

    previewService.completers[1].complete(
      MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: MealType.lunch,
            protein: 'meat',
            count: 5,
            portionsPerMeal: 3,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Regenerated note.',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Regenerated note.'), findsOneWidget);
    expect(find.descendant(of: lunchCard, matching: find.byIcon(Icons.refresh)), findsOneWidget);
  });

  testWidgets('shows an error snackbar when a slot regenerate call fails', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    var callCount = 0;
    final previewService = _FakePreviewService((mealSlots, portionsPerMeal, items) async {
      callCount++;
      if (callCount == 1) {
        return MealPlanPreview(
          slots: [
            MealSlotPreview(
              mealType: MealType.lunch,
              protein: 'meat',
              count: 5,
              portionsPerMeal: portionsPerMeal,
              anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
              note: 'Big-batch chicken thigh stir-fry.',
            ),
          ],
        );
      }
      throw Exception('boom');
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Regenerate suggested items'));
    await tester.pumpAndSettle();

    expect(find.text('Could not regenerate these suggestions: boom'), findsOneWidget);
    // The original slot is untouched and the button is usable again.
    expect(find.text('Big-batch chicken thigh stir-fry.'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(of: find.byTooltip('Regenerate suggested items'), matching: find.byType(IconButton)),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('cancelling the add-item dialog leaves the anchors unchanged', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
        DealItem(
          name: 'Ground pork',
          price: '4.49\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Big-batch chicken thigh stir-fry.',
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();
    expect(find.text('Add anchor item'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Exact chip text - the picker tile above shows the same anchor's bare
    // name in its own protein-summary row.
    expect(find.text('Chicken thighs · IGA'), findsOneWidget);
    expect(find.textContaining('Ground pork'), findsNothing);
  });

  testWidgets('prompts for the next model when a slot regenerate call is still rate limited, and continues with it', (
    tester,
  ) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');
    await aiConfigRepo.saveModels(['model-a', 'model-b']);

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    // Every previewMealPlan call (both the initial generate and the slot
    // regenerate) starts a fresh ModelFallbackController from model-a, so
    // this fake rate-limits and prompts on every call, not just the first.
    final previewService = _FakeModelAwarePreviewService((model) async {
      if (model == 'model-a') throw RateLimitedException(model);
      return MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: MealType.lunch,
            protein: 'meat',
            count: 5,
            portionsPerMeal: 3,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'note',
          ),
        ],
      );
    });

    var promptCalls = 0;
    String? promptedCurrent;
    String? promptedNext;

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
          rateLimitWait: Duration.zero,
          rateLimitPrompt: (context, {required currentModel, nextModel}) async {
            promptCalls++;
            promptedCurrent = currentModel;
            promptedNext = nextModel;
            return RateLimitChoice.nextModel;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    expect(promptCalls, 1, reason: 'the initial generate call rate-limited once');

    final lunchCard = find.ancestor(of: find.text('Lunch · meat'), matching: find.byType(Card));
    final regenerateButton = find.descendant(of: lunchCard, matching: find.byIcon(Icons.refresh));
    await tester.tap(regenerateButton);
    await tester.pumpAndSettle();

    expect(promptCalls, 2, reason: 'the regenerate call goes through its own rate-limit retry flow');
    expect(promptedCurrent, 'model-a');
    expect(promptedNext, 'model-b');
  });

  testWidgets('does not offer an anchor already used by another slot in the swap or add picker', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [
          MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5),
          MealSlot(id: 'supper-tofu', mealType: MealType.supper, protein: 'tofu', count: 4),
        ],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
        DealItem(
          name: 'Ground pork',
          price: '4.49\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
        DealItem(
          name: 'Tofu',
          price: '2.29\$',
          unit: '',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: MealType.lunch,
            protein: 'meat',
            count: 5,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Lunch note.',
          ),
          MealSlotPreview(
            mealType: MealType.supper,
            protein: 'tofu',
            count: 4,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Tofu', store: 'IGA')],
            note: 'Supper note.',
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    // Step to the supper slot and swap its Tofu anchor: Chicken thighs is
    // already used by the lunch slot, so only Ground pork should be offered.
    await tester.tap(find.byKey(const ValueKey('review-step-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tofu · IGA'));
    await tester.pumpAndSettle();
    expect(find.text('Swap anchor item'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Chicken thighs'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Ground pork'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Step back to the lunch slot and add an anchor there: Tofu is already
    // used by the supper slot, so only Ground pork should be offered there
    // too.
    await tester.tap(find.byKey(const ValueKey('review-step-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();
    expect(find.text('Add anchor item'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Tofu'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Chicken thighs'), findsNothing, reason: 'already an anchor on this slot');
    expect(find.widgetWithText(ListTile, 'Ground pork'), findsOneWidget);
  });

  testWidgets('treats the same produce name at a different store as already used too', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [
      StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga'),
      StoreConfig(id: 'metro', name: 'Metro', flyerUrl: 'https://example.com/metro'),
    ]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [
          MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5),
          MealSlot(id: 'supper-meat', mealType: MealType.supper, protein: 'meat', count: 2),
        ],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
      'metro': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
        DealItem(
          name: 'Brocoli',
          price: '1.99\$',
          unit: 'lb',
          category: DealCategory.vegetables,
          storeName: 'IGA',
          pageIndex: 1,
        ),
        DealItem(
          name: 'Rice',
          price: '2.99\$',
          unit: '',
          category: DealCategory.carbs,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
      'Metro': () async => const [
        DealItem(
          name: 'Brocoli',
          price: '2.49\$',
          unit: 'lb',
          category: DealCategory.vegetables,
          storeName: 'Metro',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: MealType.lunch,
            protein: 'meat',
            count: 5,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Brocoli', store: 'IGA')],
            note: 'Lunch note.',
          ),
          MealSlotPreview(
            mealType: MealType.supper,
            protein: 'meat',
            count: 2,
            portionsPerMeal: portionsPerMeal,
            // Deliberately not a real deal item name, so it doesn't collide
            // with anything checked below.
            anchorItems: const [AnchorItem(name: 'Ground beef', store: 'Metro')],
            note: 'Supper note.',
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    // The lunch slot is anchored on IGA's Brocoli - Metro's Brocoli is the
    // same produce under a different store, so the add picker on the
    // supper slot (stepped to below) must not offer it either.
    await tester.tap(find.byKey(const ValueKey('review-step-1')));
    await tester.pumpAndSettle();
    expect(find.text('Supper · meat'), findsOneWidget);
    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();

    expect(find.text('Add anchor item'), findsOneWidget);
    // Both listings of Brocoli (IGA and Metro) are excluded, since the lunch
    // slot already claims the ingredient regardless of which store it's
    // from - but unrelated items are still offered, proving the dialog
    // isn't just empty for an unrelated reason.
    expect(find.widgetWithText(ListTile, 'Brocoli'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Chicken thighs'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Rice'), findsOneWidget);
  });

  testWidgets('the structure step shows the current meal plan config before generating', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        dietaryNotes: 'No shellfish.',
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();

    // The saved config is shown, not yet sent to the AI - the CTA to
    // actually generate is what's on screen instead of a preview.
    expect(find.text('What to plan'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Portions per meal'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('28'), findsOneWidget);
    expect(find.text('No shellfish.'), findsOneWidget);
    expect(find.byKey(const ValueKey('structure-protein-lunch-meat')), findsOneWidget);
    expect(find.text('5 meals / week'), findsOneWidget);
    expect(find.text('Looks good, generate preview →'), findsOneWidget);
    expect(find.text('Lunch · meat'), findsNothing);
  });

  testWidgets('editing the structure step before confirming changes what is generated and persisted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          MealSlotPreview(
            mealType: mealSlots.single.mealType,
            protein: mealSlots.single.protein,
            count: mealSlots.single.count,
            portionsPerMeal: portionsPerMeal,
            anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
            note: 'Note.',
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Portions per meal'), '4');
    await tester.enterText(find.widgetWithText(TextFormField, 'Diversity window (days)'), '10');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Additional planning instructions'),
      'No fish.',
    );
    await tester.enterText(find.byKey(const ValueKey('structure-protein-lunch-meat')), 'chicken');
    await tester.enterText(find.byKey(const ValueKey('structure-count-lunch-meat')), '6');
    await tester.pumpAndSettle();

    // Edits aren't sent to the AI yet - still on the structure step.
    expect(previewService.calls, isEmpty);

    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    expect(previewService.calls.single.single.protein, 'chicken');
    expect(previewService.calls.single.single.count, 6);
    expect(previewService.portionsPerMealCalls.single, 4);
    expect(previewService.dietaryNotesCalls.single, 'No fish.');
    expect(find.text('Lunch · chicken'), findsOneWidget);

    // The edit was also persisted, so Config screen and a future regenerate
    // see it too - not just this one generation call.
    final saved = await mealPlanConfigRepository.load();
    expect(saved.portionsPerMeal, 4);
    expect(saved.diversityWindowDays, 10);
    expect(saved.dietaryNotes, 'No fish.');
    expect(saved.mealSlots.single.protein, 'chicken');
    expect(saved.mealSlots.single.count, 6);
  });

  testWidgets('adding a meal slot on the structure step includes it in what is generated and persisted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final aiConfigRepo = AiConfigRepository();
    await aiConfigRepo.saveApiKey('sk-test');

    final mealPlanConfigRepository = MealPlanConfigRepository();
    await mealPlanConfigRepository.save(
      const MealPlanConfig(
        portionsPerMeal: 3,
        diversityWindowDays: 28,
        mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      ),
    );

    final scraper = _FakePagesScraper({
      'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
    });
    final extraction = _FakeExtractionService({
      'IGA': () async => const [
        DealItem(
          name: 'Chicken thighs',
          price: '3.99\$',
          unit: 'lb',
          category: DealCategory.protein,
          storeName: 'IGA',
          pageIndex: 1,
        ),
      ],
    });

    final previewService = _FakePreviewService(
      (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
        slots: [
          for (final slot in mealSlots)
            MealSlotPreview(
              mealType: slot.mealType,
              protein: slot.protein,
              count: slot.count,
              portionsPerMeal: portionsPerMeal,
              anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
              note: 'Note.',
            ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlanifScreen(
          repository: repository,
          scraperService: scraper,
          extractionService: extraction,
          aiConfigRepository: aiConfigRepo,
          mealPlanConfigRepository: mealPlanConfigRepository,
          previewService: previewService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextFormField, 'Protein'), findsOneWidget);

    await tester.tap(find.byTooltip('Add meal slot'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextFormField, 'Protein'), findsNWidgets(2));
    expect(find.text('6 meals / week'), findsOneWidget);

    await tester.tap(find.text('Looks good, generate preview →'));
    await tester.pumpAndSettle();

    expect(previewService.calls.single.length, 2);
    final saved = await mealPlanConfigRepository.load();
    expect(saved.mealSlots.length, 2);
  });

  testWidgets(
    'removing a meal slot on the structure step drops it, disables the last remaining slot delete, and persists',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = StoreConfigRepository();
      await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

      final aiConfigRepo = AiConfigRepository();
      await aiConfigRepo.saveApiKey('sk-test');

      final mealPlanConfigRepository = MealPlanConfigRepository();
      await mealPlanConfigRepository.save(
        const MealPlanConfig(
          portionsPerMeal: 3,
          diversityWindowDays: 28,
          mealSlots: [
            MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5),
            MealSlot(id: 'supper-tofu', mealType: MealType.supper, protein: 'tofu', count: 4),
          ],
        ),
      );

      final scraper = _FakePagesScraper({
        'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
      });
      final extraction = _FakeExtractionService({
        'IGA': () async => const [
          DealItem(
            name: 'Chicken thighs',
            price: '3.99\$',
            unit: 'lb',
            category: DealCategory.protein,
            storeName: 'IGA',
            pageIndex: 1,
          ),
        ],
      });

      final previewService = _FakePreviewService(
        (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
          slots: [
            MealSlotPreview(
              mealType: mealSlots.single.mealType,
              protein: mealSlots.single.protein,
              count: mealSlots.single.count,
              portionsPerMeal: portionsPerMeal,
              anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
              note: 'Note.',
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: PlanifScreen(
            repository: repository,
            scraperService: scraper,
            extractionService: extraction,
            aiConfigRepository: aiConfigRepo,
            mealPlanConfigRepository: mealPlanConfigRepository,
            previewService: previewService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Fetch deals'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview meal plan'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, 'Protein'), findsNWidgets(2));

      await tester.tap(find.byTooltip('Remove meal slot').first);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, 'Protein'), findsOneWidget);
      expect(find.text('4 meals / week'), findsOneWidget);
      // The only remaining slot can't be removed - at least one slot must
      // stay configured, same rule as ConfigScreen's own editor.
      final removeButton = tester.widget<IconButton>(
        find.ancestor(of: find.byTooltip('Remove meal slot'), matching: find.byType(IconButton)),
      );
      expect(removeButton.onPressed, isNull);

      await tester.tap(find.text('Looks good, generate preview →'));
      await tester.pumpAndSettle();

      expect(previewService.calls.single.single.protein, 'tofu');
      final saved = await mealPlanConfigRepository.load();
      expect(saved.mealSlots.single.protein, 'tofu');
    },
  );

  testWidgets(
    'reopening the structure step from the preview view seeds it with the confirmed config, and regenerating replaces the preview',
    (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = StoreConfigRepository();
      await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

      final aiConfigRepo = AiConfigRepository();
      await aiConfigRepo.saveApiKey('sk-test');

      final mealPlanConfigRepository = MealPlanConfigRepository();
      await mealPlanConfigRepository.save(
        const MealPlanConfig(
          portionsPerMeal: 3,
          diversityWindowDays: 28,
          mealSlots: [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
        ),
      );

      final scraper = _FakePagesScraper({
        'iga': const [FlyerPage(pageNumber: 1, altText: 'x')],
      });
      final extraction = _FakeExtractionService({
        'IGA': () async => const [
          DealItem(
            name: 'Chicken thighs',
            price: '3.99\$',
            unit: 'lb',
            category: DealCategory.protein,
            storeName: 'IGA',
            pageIndex: 1,
          ),
        ],
      });

      final previewService = _FakePreviewService(
        (mealSlots, portionsPerMeal, items) async => MealPlanPreview(
          slots: [
            MealSlotPreview(
              mealType: mealSlots.single.mealType,
              protein: mealSlots.single.protein,
              count: mealSlots.single.count,
              portionsPerMeal: portionsPerMeal,
              anchorItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
              note: 'Note for ${mealSlots.single.protein}.',
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: PlanifScreen(
            repository: repository,
            scraperService: scraper,
            extractionService: extraction,
            aiConfigRepository: aiConfigRepo,
            mealPlanConfigRepository: mealPlanConfigRepository,
            previewService: previewService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Fetch deals'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview meal plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Looks good, generate preview →'));
      await tester.pumpAndSettle();

      expect(find.text('Lunch · meat'), findsOneWidget);
      expect(find.text('Note for meat.'), findsOneWidget);

      await tester.tap(find.byTooltip('Edit meal plan structure'));
      await tester.pumpAndSettle();

      // Seeded from the config the preview on screen was actually generated
      // from, not a fresh reload from the repository.
      expect(find.byKey(const ValueKey('structure-protein-lunch-meat')), findsOneWidget);
      final editable = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('structure-protein-lunch-meat')),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.controller.text, 'meat');

      await tester.enterText(find.byKey(const ValueKey('structure-protein-lunch-meat')), 'turkey');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Looks good, generate preview →'));
      await tester.pumpAndSettle();

      expect(previewService.calls.length, 2);
      expect(previewService.calls[1].single.protein, 'turkey');
      expect(find.text('Lunch · turkey'), findsOneWidget);
      expect(find.text('Note for turkey.'), findsOneWidget);
      expect(find.text('Lunch · meat'), findsNothing);
      expect(find.text('Note for meat.'), findsNothing);

      final saved = await mealPlanConfigRepository.load();
      expect(saved.mealSlots.single.protein, 'turkey');
    },
  );
}
