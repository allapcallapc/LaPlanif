import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/models/store_config.dart';
import 'package:laplanif/screens/deals_screen.dart';
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

  testWidgets('shows live per-store status and the combined item list', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [
      StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga'),
      StoreConfig(id: 'metro', name: 'Metro', flyerUrl: 'https://example.com/metro'),
    ]);

    final scraper = _FakeScraperService({
      'iga': () async => const [DealItem(name: 'Poulet', price: '3.99\$', storeName: 'IGA', pageIndex: 1)],
      'metro': () async => throw Exception('HTTP 500'),
    });

    await tester.pumpWidget(MaterialApp(home: DealsScreen(repository: repository, scraper: scraper)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Press "Fetch'), findsOneWidget);

    await tester.tap(find.text("Fetch this week's deals"));
    await tester.pumpAndSettle();

    expect(find.text('1 items'), findsOneWidget);
    expect(find.text('HTTP 500'), findsOneWidget);
    expect(find.text('Poulet'), findsOneWidget);
    expect(find.text('3.99\$'), findsOneWidget);
    expect(find.text('IGA · page 1'), findsOneWidget);
  });

  testWidgets('shows an empty state when nothing could be parsed', (tester) async {
    final repository = StoreConfigRepository();
    await repository.save(const [StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga')]);

    final scraper = _FakeScraperService({'iga': () async => throw Exception('boom')});

    await tester.pumpWidget(MaterialApp(home: DealsScreen(repository: repository, scraper: scraper)));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Fetch this week's deals"));
    await tester.pumpAndSettle();

    expect(find.text('No items found.'), findsOneWidget);
  });
}
