class ParsedFlyerItem {
  const ParsedFlyerItem({required this.name, required this.price});

  final String name;
  final String price;
}

/// Splits a flyer-page image's alt text into individual items.
///
/// The alt text on circulaire-en-ligne.ca has no consistent item
/// delimiter, so this walks the text price by price: everything since the
/// previous price (or the start of the text) becomes that price's item
/// name. A price with no name text before it (e.g. a loyalty-card price
/// immediately following the regular price) is dropped rather than kept
/// as a nameless item.
class FlyerAltTextParser {
  static final RegExp _priceRegex = RegExp(
    r'(\$\s?\d+[.,]\d{2}|\d+[.,]\d{2}\s?\$)(?:\s?/\s?(?:lb|kg))?',
    caseSensitive: false,
  );

  static List<ParsedFlyerItem> parse(String altText) {
    final text = altText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return const [];

    final matches = _priceRegex.allMatches(text).toList();
    if (matches.isEmpty) return const [];

    final items = <ParsedFlyerItem>[];
    var cursor = 0;
    for (final match in matches) {
      final name = _cleanName(text.substring(cursor, match.start));
      final price = match.group(0)!.trim();
      if (name.isNotEmpty) {
        items.add(ParsedFlyerItem(name: name, price: price));
      }
      cursor = match.end;
    }
    return items;
  }

  static String _cleanName(String raw) {
    return raw
        .replaceAll(RegExp(r'^[\s\-–—.,:;]+'), '')
        .replaceAll(RegExp(r'[\s\-–—.,:;]+$'), '')
        .trim();
  }
}
