import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/models/store_config.dart';
import 'package:laplanif/screens/planif_screen.dart';
import 'package:laplanif/services/flyer_scraper_service.dart';
import 'package:laplanif/services/store_config_repository.dart';

class _FakeScraperService extends FlyerScraperService {
  _FakeScraperService(this._handlers);

  final Map<String, Future<List<DealItem>> Function()> _handlers;

  @override
  Future<List<DealItem>> fetchDeals(StoreConfig store) {
    final handler = _handlers[store.id];
    if (handler == null) {
      throw Exception('no handler for ${store.id}');
    }
    return handler();
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

    final scraper = _FakeScraperService({
      'iga': () async => const [
        DealItem(
          name: 'Poulet rôti',
          price: '3.99\$',
          storeName: 'IGA',
          pageIndex: 1,
          isCoverPage: true,
          unitPrice: '1.33\$/kg',
        ),
        DealItem(name: 'Brocoli frais', price: '2.49\$', storeName: 'IGA', pageIndex: 2),
        DealItem(name: 'Pain baguette', price: '1.99\$', storeName: 'IGA', pageIndex: 2),
        DealItem(name: 'Papier essuie-tout', price: '4.99\$', storeName: 'IGA', pageIndex: 2),
      ],
      'metro': () async => throw Exception('HTTP 500'),
    });

    await tester.pumpWidget(MaterialApp(home: PlanifScreen(repository: repository, scraper: scraper)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Press "Fetch'), findsOneWidget);

    await tester.tap(find.text("Fetch this week's deals"));
    await tester.pumpAndSettle();

    // Once loaded, the per-store status collapses to a compact summary
    // chip per store instead of a full status row each.
    expect(find.text('IGA · 4'), findsOneWidget);
    expect(find.text('Metro · failed'), findsOneWidget);

    expect(find.text('Protein'), findsOneWidget);
    expect(find.text('Vegetables'), findsOneWidget);
    expect(find.text('Carbs'), findsOneWidget);
    expect(find.text('Uncategorized'), findsOneWidget);

    expect(find.text('Poulet rôti'), findsOneWidget);
    expect(find.text('Brocoli frais'), findsOneWidget);
    expect(find.text('Pain baguette'), findsOneWidget);
    expect(find.text('Papier essuie-tout'), findsOneWidget);

    expect(find.text('COVER'), findsOneWidget);
    expect(find.text('1.33\$/kg'), findsOneWidget);
  });

  testWidgets('shows the full status list while a fetch is in flight', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    // A Completer that never resolves on its own lets the test observe the
    // in-flight state deterministically, with no race against how fast the
    // fake scraper would otherwise finish.
    final completer = Completer<List<DealItem>>();
    final scraper = _FakeScraperService({'iga': () => completer.future});

    await tester.pumpWidget(MaterialApp(home: PlanifScreen(repository: repository, scraper: scraper)));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Fetch this week's deals"));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('IGA'), findsOneWidget);
    expect(find.text('Fetching…'), findsWidgets);
    expect(find.text('IGA · 1'), findsNothing);

    completer.complete(const [DealItem(name: 'Poulet', price: '3.99\$', storeName: 'IGA', pageIndex: 1)]);
    await tester.pumpAndSettle();

    expect(find.text('IGA · 1'), findsOneWidget);
  });

  testWidgets('shows an empty state when nothing could be parsed', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final scraper = _FakeScraperService({'iga': () async => throw Exception('boom')});

    await tester.pumpWidget(MaterialApp(home: PlanifScreen(repository: repository, scraper: scraper)));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Fetch this week's deals"));
    await tester.pumpAndSettle();

    expect(find.text('No items found.'), findsOneWidget);
  });
}
