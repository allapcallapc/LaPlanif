import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/services/item_categorizer.dart';

void main() {
  group('ItemCategorizer', () {
    test('matches protein keywords', () {
      expect(ItemCategorizer.categorize('Poulet entier catégorie A'), DealCategory.protein);
      expect(ItemCategorizer.categorize('Filets de saumon'), DealCategory.protein);
      expect(ItemCategorizer.categorize('Fromage cheddar fort'), DealCategory.protein);
    });

    test('matches carbs keywords', () {
      expect(ItemCategorizer.categorize('Pain baguette tranché'), DealCategory.carbs);
      expect(ItemCategorizer.categorize('Riz basmati 2kg'), DealCategory.carbs);
    });

    test('matches vegetable keywords', () {
      expect(ItemCategorizer.categorize('Brocoli frais'), DealCategory.vegetables);
      expect(ItemCategorizer.categorize('Pommes Cortland sac de 3lb'), DealCategory.vegetables);
    });

    test('is case-insensitive', () {
      expect(ItemCategorizer.categorize('POULET ENTIER'), DealCategory.protein);
    });

    test('falls back to uncategorized when nothing matches', () {
      expect(ItemCategorizer.categorize('Papier essuie-tout'), DealCategory.uncategorized);
    });

    test('checks protein before carbs before vegetables when multiple match', () {
      // Contains both a protein keyword ("porc") and a carbs keyword ("pain") - protein wins.
      expect(ItemCategorizer.categorize('Pain de porc'), DealCategory.protein);
      // Contains both a carbs keyword ("riz") and a vegetable keyword ("chou") - carbs wins.
      expect(ItemCategorizer.categorize('Riz et chou frit'), DealCategory.carbs);
    });
  });
}
