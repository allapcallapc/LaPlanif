import 'dart:convert';

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
  static final _pageNumberPattern = RegExp(r'-\s*Page\s+(\d+)\b');

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
    for (final img in images) {
      final alt = img.attributes['alt'];
      if (alt == null || alt.trim().isEmpty) continue;
      final match = _pageNumberPattern.firstMatch(alt);
      if (match == null) continue;
      pages.add(FlyerPage(pageNumber: int.parse(match.group(1)!), altText: alt.trim()));
    }

    if (pages.isEmpty) {
      throw Exception('No flyer pages found on page');
    }
    return pages;
  }
}
