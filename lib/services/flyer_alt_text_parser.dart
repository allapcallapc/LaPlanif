class ParsedFlyerItem {
  const ParsedFlyerItem({required this.name, required this.price, this.unitPrice});

  final String name;
  final String price;
  final String? unitPrice;
}

/// Splits a flyer-page image's alt text into individual items.
///
/// The alt text is narrative prose describing the page, not a delimited
/// list, so this works clause by clause (splitting on ". " and "; " -
/// safe here since this locale's decimal prices use a comma, not a
/// period, and semicolons are how these descriptions enumerate several
/// items within a single sentence, e.g. "... à 2,99 $ la livre; des
/// poivrons ... à 2,49 $ la livre; ..."):
/// - A clause with no price at all is a page intro/theme description,
///   not a deal, and is discarded.
/// - A clause starting with a continuation phrase ("ce qui revient à")
///   doesn't start a new item; its price is attached to the previous item
///   as a secondary unit price instead.
/// - Any other priced clause becomes one item, named from its text with
///   the trailing "pour <price>" (or just the price) stripped.
///
/// This is a heuristic over prose, not structured data, so it won't be
/// perfect on every clause - it targets the clear failure modes above
/// (intro text as a fake item, unit-price clauses as fake items, and a
/// whole semicolon-separated list swallowed as a single fake item).
class FlyerAltTextParser {
  static final RegExp _priceRegex = RegExp(
    r'(\$\s?\d+[.,]\d{2}|\d+[.,]\d{2}\s?\$)(?:\s?/\s?(?:lb|kg))?',
    caseSensitive: false,
  );

  static final RegExp _sentenceSplitRegex = RegExp(r'[.;]\s+');

  // No trailing \b: Dart/JS regex's \b is ASCII \w-only, so it never
  // matches right after the accented "à" and would silently prevent
  // this from ever matching.
  static final RegExp _continuationRegex = RegExp(r'^ce qui revient à', caseSensitive: false);

  static final RegExp _trailingPourRegex = RegExp(r'\s*\bpour\s*$', caseSensitive: false);

  static List<ParsedFlyerItem> parse(String altText) {
    final text = altText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return const [];

    final clauses = text.split(_sentenceSplitRegex).map((s) => s.trim()).where((s) => s.isNotEmpty);

    final items = <ParsedFlyerItem>[];
    for (final clause in clauses) {
      final matches = _priceRegex.allMatches(clause).toList();
      if (matches.isEmpty) continue;

      final price = matches.last.group(0)!.trim();

      if (_continuationRegex.hasMatch(clause)) {
        if (items.isNotEmpty) {
          final previous = items.removeLast();
          items.add(ParsedFlyerItem(name: previous.name, price: previous.price, unitPrice: price));
        }
        continue;
      }

      final namePart = clause.substring(0, matches.last.start).replaceFirst(_trailingPourRegex, '');
      final name = _cleanName(namePart);
      if (name.isEmpty) continue;

      items.add(ParsedFlyerItem(name: name, price: price));
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
