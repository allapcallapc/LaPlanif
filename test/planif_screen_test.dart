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

    expect(find.text('4 items'), findsOneWidget);
    expect(find.text('HTTP 500'), findsOneWidget);

    expect(find.text('Protein'), findsOneWidget);
    expect(find.text('Vegetables'), findsOneWidget);
    expect(find.text('Carbs'), findsOneWidget);
    expect(find.text('Uncategorized'), findsOneWidget);

    expect(find.text('Poulet rôti'), findsOneWidget);
    expect(find.text('Brocoli frais'), findsOneWidget);
    expect(find.text('Pain baguette'), findsOneWidget);
    expect(find.text('Papier essuie-tout'), findsOneWidget);

    expect(find.byIcon(Icons.star), findsOneWidget);
    expect(find.text('1.33\$/kg'), findsOneWidget);
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
