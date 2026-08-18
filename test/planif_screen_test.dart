import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/models/flyer_page.dart';
import 'package:laplanif/models/store_config.dart';
import 'package:laplanif/screens/planif_screen.dart';
import 'package:laplanif/services/ai_config_repository.dart';
import 'package:laplanif/services/ai_deal_extraction_service.dart';
import 'package:laplanif/services/flyer_scraper_service.dart';
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
    // but chunk 1's already-extracted item isn't thrown away.
    expect(find.text('IGA · failed, tap to retry'), findsOneWidget);
    expect(find.text('Poulet'), findsOneWidget);
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
}
