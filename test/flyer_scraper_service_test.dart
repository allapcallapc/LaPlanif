import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:laplanif/models/store_config.dart';
import 'package:laplanif/services/flyer_scraper_service.dart';

void main() {
  const store = StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga');

  test('parses items out of every img alt attribute on the page', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), store.flyerUrl);
      return http.Response('''
        <html><body>
          <img alt="Poulet entier 3.99\$/lb">
          <img alt="">
          <img alt="Fromage cheddar 500g 6.99\$">
        </body></html>
      ''', 200);
    });

    final items = await FlyerScraperService(client: client).fetchDeals(store);

    expect(items.length, 2);
    expect(items[0].name, 'Poulet entier');
    expect(items[0].price, '3.99\$/lb');
    expect(items[0].storeName, 'IGA');
    expect(items[0].pageIndex, 1);
    expect(items[0].isCoverPage, isTrue);
    expect(items[1].name, 'Fromage cheddar 500g');
    expect(items[1].pageIndex, 3);
    expect(items[1].isCoverPage, isFalse);
  });

  test('cover page is the first image that actually has parseable content', () async {
    final client = MockClient((request) async {
      return http.Response('''
        <html><body>
          <img alt="">
          <img alt="Fromage cheddar 500g 6.99\$">
        </body></html>
      ''', 200);
    });

    final items = await FlyerScraperService(client: client).fetchDeals(store);

    expect(items.length, 1);
    expect(items[0].pageIndex, 2);
    expect(items[0].isCoverPage, isTrue);
  });

  test('threads a parsed unit price through onto the deal item', () async {
    final client = MockClient((request) async {
      return http.Response('''
        <html><body>
          <img alt="En vedette, une caisse de fraises pour 25,00 \$. Ce qui revient à 2,50 \$ le panier.">
        </body></html>
      ''', 200);
    });

    final items = await FlyerScraperService(client: client).fetchDeals(store);

    expect(items.length, 1);
    expect(items[0].price, '25,00 \$');
    expect(items[0].unitPrice, '2,50 \$');
  });

  test('throws when the request fails', () async {
    final client = MockClient((request) async => http.Response('nope', 500));

    await expectLater(FlyerScraperService(client: client).fetchDeals(store), throwsException);
  });

  test('throws when the connection itself fails', () async {
    final client = MockClient((request) async => throw Exception('network down'));

    await expectLater(FlyerScraperService(client: client).fetchDeals(store), throwsException);
  });

  test('throws when no items can be parsed', () async {
    final client = MockClient((request) async => http.Response('<html></html>', 200));

    await expectLater(FlyerScraperService(client: client).fetchDeals(store), throwsException);
  });
}
