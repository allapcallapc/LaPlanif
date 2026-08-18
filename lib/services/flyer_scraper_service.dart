import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/flyer_page.dart';
import '../models/store_config.dart';

/// Fetches a store's flyer page and pulls out the raw alt text of every
/// flyer-page image, in document order. Purely deterministic - no
/// interpretation of the text itself happens here; that's AiDealExtractionService's job.
class FlyerScraperService {
  FlyerScraperService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

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

    final document = html_parser.parse(response.body);
    final images = document.querySelectorAll('img');

    final pages = <FlyerPage>[];
    for (final img in images) {
      final alt = img.attributes['alt'];
      if (alt == null || alt.trim().isEmpty) continue;
      pages.add(FlyerPage(pageNumber: pages.length + 1, altText: alt.trim()));
    }

    if (pages.isEmpty) {
      throw Exception('No flyer pages found on page');
    }
    return pages;
  }
}
