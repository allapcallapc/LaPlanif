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
  // The separator may be a plain hyphen or an en/em dash: those are
  // typographic variants of the same label and can't be confused with
  // anything else on the page. The match is otherwise kept as strict as the
  // site's own label - looser rules (title attribute, "(Page N)", any case)
  // also match "other circulars" thumbnails and "voir page N" mentions inside
  // descriptions.
  static final _pageNumberPattern = RegExp(r'[-\u2013\u2014]\s*Page\s+(\d+)\b');

  /// Minimum alt-text length for an unnumbered image to be taken as the
  /// cover by [_unlabeledCover]. Logos and "other circulars" thumbnails carry
  /// short labels ("Logo Maxi", "Circulaire Maxi"); a real flyer page
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
    // Position in [images] of each page's <img>, parallel to [pages].
    final imageIndexes = <int>[];
    for (var i = 0; i < images.length; i++) {
      final alt = _altText(images[i]);
      final match = _pageNumberPattern.firstMatch(alt);
      if (match == null) continue;
      pages.add(FlyerPage(pageNumber: int.parse(match.group(1)!), altText: alt));
      imageIndexes.add(i);
    }

    final cover = _unlabeledCover(images, pages, imageIndexes);
    if (cover != null) pages.insert(0, cover);

    if (pages.isEmpty) {
      throw Exception('No flyer pages found on page');
    }
    return pages;
  }

  static String _altText(Element img) => img.attributes['alt']?.trim() ?? '';

  /// Maxi's flyer (seen Oct-Nov 2026) labels every page `Maxi - Page N`
  /// except the cover, so page 1 was dropped entirely - taking its deals,
  /// and every `DealItem.isCoverPage` flag, with it.
  ///
  /// Recovers the cover only in that exact situation: the lowest labeled
  /// page is 2, and the `<img>` immediately before page 2's (no skipping
  /// past other images) has a real description of at least
  /// [_minCoverTextLength] characters. Anything looser risks sending a
  /// banner or another flyer's thumbnail to the AI as "page 1" and marking
  /// its items as cover deals - worse than leaving the cover out.
  static FlyerPage? _unlabeledCover(List<Element> images, List<FlyerPage> pages, List<int> imageIndexes) {
    if (pages.isEmpty) return null;
    final lowest = pages.map((p) => p.pageNumber).reduce((a, b) => a < b ? a : b);
    if (lowest != 2) return null;

    final page2ImageIndex = imageIndexes[pages.indexWhere((p) => p.pageNumber == 2)];
    if (page2ImageIndex == 0) return null;
    final text = _altText(images[page2ImageIndex - 1]);
    if (text.length < _minCoverTextLength) return null;
    return FlyerPage(pageNumber: 1, altText: text);
  }
}
