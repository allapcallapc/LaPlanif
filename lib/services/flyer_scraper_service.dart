import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/deal_item.dart';
import '../models/store_config.dart';
import 'flyer_alt_text_parser.dart';

class FlyerScraperService {
  Future<List<DealItem>> fetchDeals(StoreConfig store) async {
    final http.Response response;
    try {
      response = await http.get(Uri.parse(store.flyerUrl));
    } catch (_) {
      throw Exception('Could not reach the page');
    }
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final document = html_parser.parse(response.body);
    final images = document.querySelectorAll('img');

    final items = <DealItem>[];
    for (var i = 0; i < images.length; i++) {
      final alt = images[i].attributes['alt'];
      if (alt == null || alt.trim().isEmpty) continue;
      final parsed = FlyerAltTextParser.parse(alt);
      for (final entry in parsed) {
        items.add(
          DealItem(name: entry.name, price: entry.price, storeName: store.name, pageIndex: i + 1),
        );
      }
    }

    if (items.isEmpty) {
      throw Exception('No items found on page');
    }
    return items;
  }
}
