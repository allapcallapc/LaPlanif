import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:laplanif/models/flyer_page.dart';
import 'package:laplanif/models/store_config.dart';
import 'package:laplanif/services/flyer_scraper_service.dart';

void main() {
  const store = StoreConfig(id: 'iga', name: 'IGA', flyerUrl: 'https://example.com/iga');

  test('extracts the page number embedded in the alt text, ignoring position', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), store.flyerUrl);
      return http.Response('''
        <html><body>
          <img alt="Circulaire IGA - Page 1. Poulet entier 3.99\$/lb">
          <img alt="">
          <img alt="Circulaire IGA - Page 2. Fromage cheddar 500g 6.99\$">
        </body></html>
      ''', 200);
    });

    final pages = await FlyerScraperService(client: client).fetchPages(store);

    expect(pages.length, 2);
    expect(pages[0].pageNumber, 1);
    expect(pages[0].altText, 'Circulaire IGA - Page 1. Poulet entier 3.99\$/lb');
    expect(pages[1].pageNumber, 2);
    expect(pages[1].altText, 'Circulaire IGA - Page 2. Fromage cheddar 500g 6.99\$');
  });

  // Regression test built from circulaire-en-ligne.ca's real markup (Metro):
  // dozens of unrelated <img alt="..."> tags (site logo, nav icons, "other
  // circulars" thumbnails, recipe category icons) appear before the actual
  // flyer carousel, all with non-empty alt text. Numbering pages by simply
  // counting every <img> with alt text put the flyer's real page 1 at
  // "page 30-something" instead of 1 - which is why isCoverPage (pageNumber
  // == 1) never matched anything real. The fix reads the page number the
  // site itself embeds in each real flyer image's alt text ("- Page N")
  // instead of counting position.
  test('ignores the noise images that precede the real flyer carousel on circulaire-en-ligne.ca', () async {
    final client = MockClient((request) async {
      return http.Response(
        '''
        <html><body>
          <img src="/topbar-inscription.png" alt="Inscription">
          <img src="/topbar-fb.png" alt="facebook">
          <img class="img-fluid" src="/logo-red.png" alt="Circulaire en ligne">
          <img class="img-thumbnail" src="/canac.jpg" alt="Circulaire Canac">
          <img class="img-thumbnail" src="/canadian-tire.jpg" alt="Circulaire Canadian Tire">
          <img class="img-thumbnail" src="/jean-coutu.jpg" alt="Circulaire Jean Coutu">
          <img alt="Entrée - brochettes tomates et feta" src="/entrees.png">
          <img alt="Accompagnement - pommes de terres" src="/accompagnements.png">
          <img src="/metro_logo.jpg" class="mainlogo" alt="Logo Metro">
          <img src="/metro_logo.jpg" width="80" height="80" title="Metro" alt="Logo Metro">
          <img alt="Circulaire Metro" title="Circulaire Metro" src="/circulaire-metro_01.jpg">
          <img alt="Circulaire Metro - À Go !" title="Circulaire Metro - À Go !" src="/circulaire-metro-a-go_01.jpg">
          <img alt="Circulaire Metro" title="Circulaire Metro" src="/next-week_01.webp">
          <img src="/rabais-epicerie-semaine_1.jpg" width="300" height="157" class="img-fluid">
          <img
            src="/circulaire-metro_01.jpg"
            alt="Circulaire Metro - Page 1. Bœuf haché mi-maigre 4,99 \$/lb."
            title="Circulaire Metro - Offres d'épicerie (Page 1)"
            width="1280" height="2560" class="img-fluid" />
          <img
            src="/circulaire-metro_02.jpg"
            alt="Circulaire Metro - Page 2. Pâté aux trois viandes 5,99 \$."
            title="Produits Irrésistibles (Page 2)"
            width="1280" height="2560" class="img-fluid" />
          <img
            src="/circulaire-metro_11.jpg"
            alt="Circulaire Metro - Page 11"
            title="Circulaire Metro - Page 11"
            width="1280" height="2560" class="img-fluid" />
        </body></html>
      ''',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    });

    final pages = await FlyerScraperService(client: client).fetchPages(store);

    expect(pages.length, 3);
    expect(pages[0].pageNumber, 1);
    expect(pages[0].altText, contains('Bœuf haché mi-maigre'));
    expect(pages[1].pageNumber, 2);
    expect(pages[1].altText, contains('Pâté aux trois viandes'));
    expect(pages[2].pageNumber, 11);
    expect(pages[2].altText, 'Circulaire Metro - Page 11');
  });

  // package:http's Response.body decodes using the charset from the
  // Content-Type header, defaulting to latin1 when the header omits one -
  // which real sites commonly do when they only declare UTF-8 via an HTML
  // <meta charset> tag. Using Response.bytes (rather than the String
  // constructor used elsewhere in this file) reproduces that faithfully:
  // the bytes are genuinely UTF-8-encoded French text, with no charset in
  // the header to hint at that.
  test('decodes the response as UTF-8 even when the Content-Type header omits a charset', () async {
    const html = '''
      <html><body>
        <img alt="Circulaire Metro - Page 1. Bœuf haché mi-maigre 4,99 \$/lb. Crème glacée 5,49 \$.">
      </body></html>
    ''';
    final client = MockClient((request) async {
      return http.Response.bytes(utf8.encode(html), 200, headers: {'content-type': 'text/html'});
    });

    final pages = await FlyerScraperService(client: client).fetchPages(store);

    expect(pages.single.altText, contains('Bœuf haché mi-maigre'));
    expect(pages.single.altText, contains('Crème glacée'));
  });

  // Maxi's flyer (Oct-Nov 2026) was scraped starting at "Page 2": the cover
  // image didn't carry the "- Page 1" label every other page has, so it was
  // skipped - losing its deals and every isCoverPage flag.
  group('Maxi cover page labeled differently from the other pages', () {
    const maxi = StoreConfig(id: 'maxi', name: 'Maxi', flyerUrl: 'https://example.com/maxi');
    const coverDeals = 'Poitrines de poulet désossées 3,99 \$/lb et pommes Gala 1,99 \$.';
    const page2 = '<img src="/circulaire-maxi_02.jpg" alt="Maxi - Page 2. Légumes surgelés (750 g) à 2,50 \$.">';
    const page3 = '<img src="/circulaire-maxi_03.jpg" alt="Maxi - Page 3. Beurre (454 g) à 5,50 \$.">';

    Future<List<FlyerPage>> scrape(String images) {
      final client = MockClient((request) async {
        return http.Response(
          '<html><body><img src="/logo-maxi.jpg" alt="Logo Maxi">$images</body></html>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      });
      return FlyerScraperService(client: client).fetchPages(maxi);
    }

    test('accepts an en or em dash as the separator', () async {
      // A short spacer image sits between each cover and page 2, so the
      // unlabeled-cover fallback can't be what finds them: only the regex.
      for (final dash in ['–', '—']) {
        final pages = await scrape('<img alt="Maxi $dash Page 1. Poulet"><img alt="Pub">$page2');
        expect(pages.map((p) => p.pageNumber), [1, 2], reason: 'dash: $dash');
        expect(pages[0].altText, 'Maxi $dash Page 1. Poulet');
      }
    });

    test('takes the described image right before page 2 as the cover', () async {
      final pages = await scrape('<img alt="Maxi - Couverture. $coverDeals">$page2$page3');

      expect(pages.map((p) => p.pageNumber), [1, 2, 3]);
      expect(pages[0].altText, contains('Poitrines de poulet'));
    });

    test('does not take a short logo/thumbnail label as the cover', () async {
      final pages = await scrape('<img alt="Circulaire Maxi" src="/circulaire-maxi_01.jpg">$page2$page3');

      expect(pages.map((p) => p.pageNumber), [2, 3]);
    });

    test('does not skip past an image without text to reach an earlier banner', () async {
      final pages = await scrape(
        '<img alt="Inscrivez-vous à notre infolettre pour recevoir vos circulaires chaque semaine">'
        '<img src="/cover-lazy.jpg" alt="">'
        '$page2$page3',
      );

      expect(pages.map((p) => p.pageNumber), [2, 3]);
    });

    test('does not invent a cover when the lowest labeled page is not 2', () async {
      final pages = await scrape('<img alt="Maxi - Couverture. $coverDeals">$page3');

      expect(pages.map((p) => p.pageNumber), [3]);
    });

    test('ignores page numbers in titles and inside descriptions', () async {
      final pages = await scrape(
        '<img alt="Circulaire IGA" title="Circulaire IGA (Page 1)">'
        '<img alt="Maxi. Fromage en promo (voir page 4) et lait 2 L à 4,99 \$.">'
        '$page2',
      );

      // The second image is unlabeled and right before page 2, so it is the
      // cover - numbered 1, not 4; the IGA thumbnail is not a page at all.
      expect(pages.map((p) => p.pageNumber), [1, 2]);
      expect(pages[0].altText, contains('Fromage en promo'));
    });
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

  test('throws when images have alt text but none match the flyer page pattern', () async {
    final client = MockClient(
      (request) async => http.Response('<html><img alt="Logo Metro"><img alt="Circulaire Metro"></html>', 200),
    );

    await expectLater(FlyerScraperService(client: client).fetchPages(store), throwsException);
  });
}
