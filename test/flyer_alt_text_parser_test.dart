import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/services/flyer_alt_text_parser.dart';

void main() {
  group('FlyerAltTextParser', () {
    test('discards intro/theme sentences with no price', () {
      const alt =
          'Circulaire IGA - Page 1. '
          'La page annonce un "Festival des prix bouffés" avec un personnage animé et des ballons. '
          'Côtelettes de porc St-Hubert 9,99 \$.';

      final items = FlyerAltTextParser.parse(alt);

      expect(items.length, 1);
      expect(items[0].name, 'Côtelettes de porc St-Hubert');
      expect(items[0].price, '9,99 \$');
    });

    test('attaches a "ce qui revient à" clause to the previous item as a unit price', () {
      const alt =
          'En vedette, une caisse de 10 paniers de 1 litre de fraises, produit du Québec, pour 25,00 \$. '
          'Ce qui revient à 2,50 \$ le panier. '
          'On trouve aussi les côtelettes de porc St-Hubert, miel épicé, pour 9,99 \$.';

      final items = FlyerAltTextParser.parse(alt);

      expect(items.length, 2);
      expect(items[0].name, 'En vedette, une caisse de 10 paniers de 1 litre de fraises, produit du Québec');
      expect(items[0].price, '25,00 \$');
      expect(items[0].unitPrice, '2,50 \$');
      expect(items[1].name, 'On trouve aussi les côtelettes de porc St-Hubert, miel épicé');
      expect(items[1].price, '9,99 \$');
      expect(items[1].unitPrice, isNull);
    });

    test('drops a continuation clause with nothing preceding it to attach to', () {
      const alt = 'Ce qui revient à 2,50 \$ le panier.';

      final items = FlyerAltTextParser.parse(alt);

      expect(items, isEmpty);
    });

    test('strips a trailing price with no "pour" the same as one with it', () {
      const alt = 'Fromage cheddar fort 500g 6,99 \$.';

      final items = FlyerAltTextParser.parse(alt);

      expect(items.length, 1);
      expect(items[0].name, 'Fromage cheddar fort 500g');
      expect(items[0].price, '6,99 \$');
    });

    test('splits a semicolon-separated list of items within one sentence', () {
      const alt =
          'On y trouve : des haricots verts ou jaunes à 2,99 \$ la livre; '
          'des carottes nantaises à 2,99 \$ la livre; '
          'du céleri à 1,99 \$.';

      final items = FlyerAltTextParser.parse(alt);

      expect(items.length, 3);
      expect(items[0].name, 'On y trouve : des haricots verts ou jaunes à');
      expect(items[0].price, '2,99 \$');
      expect(items[1].name, 'des carottes nantaises à');
      expect(items[1].price, '2,99 \$');
      expect(items[2].name, 'du céleri à');
      expect(items[2].price, '1,99 \$');
    });

    test('returns nothing when no price is present', () {
      expect(FlyerAltTextParser.parse('Page couverture de la circulaire'), isEmpty);
    });

    test('handles empty input', () {
      expect(FlyerAltTextParser.parse(''), isEmpty);
    });
  });
}
