import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/flyer_page.dart';
import '../models/store_config.dart';

/// Fetches a store's flyer page and pulls out the raw alt text of every
/// actual flyer-page image, in document order. Purely deterministic - no
/// interpretation of the text itself happens here; that's AiDealExtractionService's job.
class FlyerScraperService {
  FlyerScraperService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  // circulaire-en-ligne.ca's own alt-text pipeline tags every real flyer
  // page image with "<Store> - Page <N>" (optionally followed by a longer
  // description). The page itself carries dozens of *other* <img> tags with
  // non-empty alt text before the flyer carousel even starts - site logo,
  // nav icons, "other circulars" thumbnails, recipe category icons, etc. -
  // so numbering pages by simply counting every <img> with alt text badly
  // over-numbers the real pages (page 1 of the flyer can end up labeled
  // page 30+). Anchoring on this "- Page N" marker instead both filters out
  // that noise and recovers the flyer's true page number directly.
  //
  // The match is deliberately tolerant of how the separator is typed (plain
  // hyphen, en/em dash, colon, or an opening parenthesis as in the site's
  // "(Page N)" titles) and of letter case: a single label variant on one
  // page - most often the cover - would otherwise silently drop that whole
  // page, and the cover is exactly where the featured deals live.
  static final _pageNumberPattern = RegExp(r'[-\u2013\u2014:(]\s*Page\s*(\d+)\b', caseSensitive: false);

  /// Minimum length for an unnumbered image's text to be taken as the cover
  /// page by [_findUnlabeledCover]. Logos and "other circulars" thumbnails
  /// carry short labels ("Logo Maxi", "Circulaire Maxi"); a real flyer page
  /// carries a prose description of its deals.
  static const _minCoverTextLength = 40;

  Future<List<FlyerPage>> fetchPages(StoreConfig store) async {
    final http.Response response;
    try {
      response = await _client.get(Uri.parse(store.flyerUrl));
    } catch (_) {
      throw Exception('Could not reach the page');
    }
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    // response.body would decode using the Content-Type header's charset,
    // defaulting to latin1 when the header omits one - common for sites
    // (like circulaire-en-ligne.ca) that only declare UTF-8 via an HTML
    // <meta charset> tag rather than the HTTP header, which would silently
    // corrupt every accented character (à, é, œ, ç...) in the French alt
    // text. Decode the raw bytes as UTF-8 directly instead; allowMalformed
    // degrades gracefully rather than throwing if a page genuinely isn't
    // UTF-8.
    final document = html_parser.parse(utf8.decode(response.bodyBytes, allowMalformed: true));
    final images = document.querySelectorAll('img');

    final pages = <FlyerPage>[];
    // Index into [images] of each page's <img>, parallel to [pages].
    final imageIndexes = <int>[];
    for (var i = 0; i < images.length; i++) {
      final page = _labeledPage(images[i]);
      if (page == null) continue;
      pages.add(page);
      imageIndexes.add(i);
    }

    if (pages.isNotEmpty && !pages.any((p) => p.pageNumber == 1)) {
      final cover = _findUnlabeledCover(images, imageIndexes[0]);
      if (cover != null) pages.insert(0, cover);
    }

    if (pages.isEmpty) {
      throw Exception('No flyer pages found on page');
    }
    return pages;
  }

  /// Reads the page number from the image's alt text, falling back to its
  /// title attribute (the site also writes "... (Page N)" there) when the
  /// alt text carries none. The returned page's text is the alt text when
  /// there is one, since that's what holds the deal descriptions.
  FlyerPage? _labeledPage(Element img) {
    final alt = img.attributes['alt']?.trim() ?? '';
    final title = img.attributes['title']?.trim() ?? '';
    final match = _pageNumberPattern.firstMatch(alt) ?? _pageNumberPattern.firstMatch(title);
    if (match == null) return null;
    final text = alt.isNotEmpty ? alt : title;
    return FlyerPage(pageNumber: int.parse(match.group(1)!), altText: text);
  }

  /// Some flyers (Maxi, seen Oct-Nov 2026) label every page "`<Store> - Page
  /// N`" except the cover, so page 1 was being dropped entirely - taking its
  /// deals, and every [DealItem.isCoverPage] flag, with it. When no page 1
  /// was found, take the nearest image just before the first numbered page
  /// as the cover, provided it carries a real description (see
  /// [_minCoverTextLength]) rather than a logo/thumbnail label.
  FlyerPage? _findUnlabeledCover(List<Element> images, int firstPageImageIndex) {
    for (var i = firstPageImageIndex - 1; i >= 0; i--) {
      final img = images[i];
      final alt = img.attributes['alt']?.trim() ?? '';
      final title = img.attributes['title']?.trim() ?? '';
      final text = alt.length >= title.length ? alt : title;
      if (text.isEmpty) continue;
      if (text.length < _minCoverTextLength) return null;
      return FlyerPage(pageNumber: 1, altText: text);
    }
    return null;
  }
}
