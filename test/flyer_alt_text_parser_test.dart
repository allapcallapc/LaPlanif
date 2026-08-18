import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/services/flyer_alt_text_parser.dart';

void main() {
  group('FlyerAltTextParser', () {
    test('splits multiple items separated by prices', () {
      const alt = 'Poulet entier categorie A 3.99\$/lb '
          'Fromage cheddar fort 500g 6.99\$ '
          'Cafe moulu 340g \$4.99';

      final items = FlyerAltTextParser.parse(alt);

      expect(items.length, 3);
      expect(items[0].name, 'Poulet entier categorie A');
      expect(items[0].price, '3.99\$/lb');
      expect(items[1].name, 'Fromage cheddar fort 500g');
      expect(items[1].price, '6.99\$');
      expect(items[2].name, 'Cafe moulu 340g');
      expect(items[2].price, '\$4.99');
    });

    test('returns nothing when no price is present', () {
      expect(FlyerAltTextParser.parse('Page couverture de la circulaire'), isEmpty);
    });

    test('handles empty input', () {
      expect(FlyerAltTextParser.parse(''), isEmpty);
    });

    test('drops a price with no preceding name text', () {
      const alt = 'Item 3.99\$ 4.49\$';
      final items = FlyerAltTextParser.parse(alt);
      expect(items.length, 1);
      expect(items[0].name, 'Item');
      expect(items[0].price, '3.99\$');
    });
  });
}
