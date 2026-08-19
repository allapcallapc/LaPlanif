import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/models/flyer_page.dart';
import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_preview.dart';
import 'package:laplanif/models/store_config.dart';
import 'package:laplanif/screens/planif_screen.dart';
import 'package:laplanif/services/ai_config_repository.dart';
import 'package:laplanif/services/ai_deal_extraction_service.dart';
import 'package:laplanif/services/deal_preference_repository.dart';
import 'package:laplanif/services/flyer_scraper_service.dart';
import 'package:laplanif/services/meal_plan_config_repository.dart';
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

  @override
  Future<MealPlanPreview> previewMealPlan({
    required String apiKey,
    required List<MealSlot> mealSlots,
    required int portionsPerMeal,
    required List<DealItem> items,
    String? model,
  }) {
    calls.add(mealSlots);
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
    String? model,
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
  });

  testWidgets('tapping an item cycles its preference, updates the summary, and persists across reload', (
    tester,
  ) async {
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

    // Re-fetching (e.g. after reopening the app) re-applies the persisted
    // exclusion instead of resetting every item back to neutral.
    await tester.tap(find.text('Fetch deals'));
    await tester.pumpAndSettle();
    expect(find.text('0 priority, 1 excluded'), findsOneWidget);

    // excluded -> neutral, which also clears the persisted entry.
    await tester.tap(find.text('Poulet'));
    await tester.pumpAndSettle();
    expect(find.text('0 priority, 0 excluded'), findsOneWidget);
    expect(await preferenceRepository.loadAll(), isEmpty);
  });

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

    await tester.tap(find.widgetWithText(ChoiceChip, 'IGA'));
    await tester.pumpAndSettle();

    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Fromage'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();

    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Fromage'), findsOneWidget);
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

  testWidgets('shows a retrying chip and disables Fetch deals while a single store retries', (tester) async {
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
    expect(find.text('Fetching…'), findsOneWidget);
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

    expect(find.text('IGA · 1'), findsOneWidget);
    expect(find.text('Poulet'), findsOneWidget);
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

    // Both stores have items, so the filter row is showing.
    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Fromage'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'IGA'));
    await tester.pumpAndSettle();

    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('Fromage'), findsNothing);

    await tester.tap(find.text('IGA · 1 kept, failed, tap to retry'));
    await tester.pumpAndSettle();

    // The retry left IGA with zero items, so filtering to "IGA" would show
    // nothing with no way back - the filter should have reset instead.
    expect(find.text('Fromage'), findsOneWidget);
  });

  testWidgets('generates a meal plan preview, swaps an anchor item, and stubs the full-plan button', (tester) async {
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

    expect(find.text('Preview meal plan'), findsOneWidget);

    await tester.tap(find.text('Preview meal plan'));
    await tester.pumpAndSettle();

    expect(find.text('Lunch · meat'), findsOneWidget);
    expect(find.text('15 portions'), findsOneWidget);
    expect(find.textContaining('Chicken thighs'), findsOneWidget);
    expect(find.text('Big-batch chicken thigh stir-fry.'), findsOneWidget);
    expect(find.text('Looks good, generate full plan →'), findsOneWidget);

    // Swap the anchor item for another available deal item.
    await tester.tap(find.textContaining('Chicken thighs'));
    await tester.pumpAndSettle();
    expect(find.text('Swap anchor item'), findsOneWidget);

    await tester.tap(find.text('Ground pork'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Ground pork'), findsOneWidget);
    expect(find.textContaining('Chicken thighs'), findsNothing);

    // Stub button just confirms the checkpoint for now - wiring comes next.
    await tester.tap(find.text('Looks good, generate full plan →'));
    await tester.pumpAndSettle();
    expect(find.text('Full recipe generation is coming soon.'), findsOneWidget);
  });

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

    expect(find.text('Could not generate preview: boom'), findsOneWidget);
    // The button falls back to its initial label instead of getting stuck
    // showing "Generating…".
    expect(find.text('Preview meal plan'), findsOneWidget);
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

    await tester.tap(find.textContaining('Chicken thighs'));
    await tester.pumpAndSettle();
    expect(find.text('Swap anchor item'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Chicken thighs'), findsOneWidget);
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

    // Generating a preview switches straight into it.
    expect(find.text('Lunch · meat'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Deal items'));
    await tester.pumpAndSettle();
    expect(find.text('Chicken thighs'), findsOneWidget);
    expect(find.text('Lunch · meat'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Meal plan preview'));
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

    expect(find.text('Original lunch note.'), findsOneWidget);
    expect(find.text('Original supper note.'), findsOneWidget);
    expect(previewService.calls.length, 1);

    final lunchCard = find.ancestor(of: find.text('Lunch · meat'), matching: find.byType(Card));
    final regenerateButton = find.descendant(of: lunchCard, matching: find.byIcon(Icons.refresh));
    await tester.tap(regenerateButton);
    await tester.pumpAndSettle();

    expect(previewService.calls.length, 2);
    expect(previewService.calls[1].length, 1);
    expect(previewService.calls[1].single.mealType, MealType.lunch);

    // Only the regenerated slot changed.
    expect(find.text('Regenerated lunch note.'), findsOneWidget);
    expect(find.textContaining('Ground pork'), findsOneWidget);
    expect(find.textContaining('Chicken thighs'), findsNothing);
    expect(find.text('Original supper note.'), findsOneWidget);
    expect(find.textContaining('Tofu'), findsOneWidget);
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

    expect(find.textContaining('Ground pork'), findsNothing);

    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();
    expect(find.text('Add anchor item'), findsOneWidget);
    // Chicken thighs is already an anchor, so it should not be offered again.
    expect(find.widgetWithText(ListTile, 'Chicken thighs'), findsNothing);

    await tester.tap(find.text('Ground pork'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Chicken thighs'), findsOneWidget);
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

    expect(find.textContaining('Chicken thighs'), findsOneWidget);

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

    final lunchCard = find.ancestor(of: find.text('Lunch · meat'), matching: find.byType(Card));
    final regenerateButton = find.descendant(of: lunchCard, matching: find.byIcon(Icons.refresh));
    await tester.tap(regenerateButton);
    await tester.pumpAndSettle();

    expect(find.text('Could not regenerate this recipe: boom'), findsOneWidget);
    // The original slot is untouched and the button is usable again.
    expect(find.text('Big-batch chicken thigh stir-fry.'), findsOneWidget);
    expect(find.descendant(of: lunchCard, matching: find.byIcon(Icons.refresh)), findsOneWidget);
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

    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();
    expect(find.text('Add anchor item'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Chicken thighs'), findsOneWidget);
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

    expect(promptCalls, 1, reason: 'the initial generate call rate-limited once');

    final lunchCard = find.ancestor(of: find.text('Lunch · meat'), matching: find.byType(Card));
    final regenerateButton = find.descendant(of: lunchCard, matching: find.byIcon(Icons.refresh));
    await tester.tap(regenerateButton);
    await tester.pumpAndSettle();

    expect(promptCalls, 2, reason: 'the regenerate call goes through its own rate-limit retry flow');
    expect(promptedCurrent, 'model-a');
    expect(promptedNext, 'model-b');
  });
}
