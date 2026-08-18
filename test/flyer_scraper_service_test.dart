import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:laplanif/models/store_config.dart';
import 'package:laplanif/services/flyer_scraper_service.dart';

void main() {
  const store = StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga');

  test('numbers pages sequentially, skipping images with no alt text', () async {
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

    final pages = await FlyerScraperService(client: client).fetchPages(store);

    expect(pages.length, 2);
    expect(pages[0].pageNumber, 1);
    expect(pages[0].altText, 'Poulet entier 3.99\$/lb');
    expect(pages[1].pageNumber, 2);
    expect(pages[1].altText, 'Fromage cheddar 500g 6.99\$');
  });

  test('throws when the request fails', () async {
    final client = MockClient((request) async => http.Response('nope', 500));

    await expectLater(FlyerScraperService(client: client).fetchPages(store), throwsException);
  });

  test('throws when the connection itself fails', () async {
    final client = MockClient((request) async => throw Exception('network down'));

    await expectLater(FlyerScraperService(client: client).fetchPages(store), throwsException);
  });

  test('throws when no page has any alt text', () async {
    final client = MockClient((request) async => http.Response('<html><img alt=""></html>', 200));

    await expectLater(FlyerScraperService(client: client).fetchPages(store), throwsException);
  });
}
