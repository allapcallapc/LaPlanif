import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/utils/ingredient_kind.dart';

void main() {
  test('recognizes the same kind across languages, varieties, brands and formats', () {
    final cases = {
      'rice': ['Riz Jasmin Dainty (format maxi 1,6 kg)', 'Basmati rice', 'Brown rice', 'riz brun Uncle Ben\'s'],
      'pasta': ['Pâtes alimentaires Compliments ou Italpasta 900 g', 'Spaghetti', 'Orzo', 'Penne rigate'],
      'potato': ['Pommes de terre grelots', 'Potatoes', 'patates jaunes'],
      'sweet potato': ['Patates douces', 'Sweet potatoes'],
      'noodles': ['Nouilles de riz', 'Egg noodles', 'Rice noodles'],
      'chicken': ['Hauts de cuisse de poulet', 'Chicken thighs', 'Poitrines de poulet', 'Chicken breast'],
      'pork': ['côtes levées de flanc de porc frais', 'Ground pork', 'Jambon toupie', 'Bacon'],
      'beef': ['Bœuf haché mi-maigre', 'Ground beef', 'Steak de surlonge'],
      'broccoli': ['couronne de brocoli (Produit du Canada)', 'Brocoli', 'Broccoli crowns'],
      'cauliflower': ['Chou-fleur', 'Cauliflower'],
      'kale': ['Chou frisé', 'Kale'],
      'cabbage': ['Chou vert', 'Red cabbage'],
      'zucchini': ['Courgettes', 'Zucchini'],
      'squash': ['Courge musquée', 'Butternut squash'],
      'pepper': ['Poivrons rouges', 'Red bell peppers'],
      'tofu': ['tofu Unisoya tofu 1,25 kg'],
      'egg': ['Oeufs gros', 'Large eggs'],
      'chickpeas': ['Pois chiches'],
      'peas': ['Petits pois surgelés', 'Green peas'],
    };
    for (final MapEntry(key: kind, value: names) in cases.entries) {
      for (final name in names) {
        expect(ingredientKind(name), kind, reason: name);
      }
    }
  });

  test('does not match a stem inside another word', () {
    expect(ingredientKind('Ricotta'), isNull);
    expect(ingredientKind('Hamburger buns'), 'bread');
    expect(ingredientKind('Pepperoni'), isNull);
    expect(ingredientKind('Codfish'), isNull);
  });

  test('returns null for an ingredient no kind covers', () {
    expect(ingredientKind('Parmesan'), isNull);
    expect(ingredientKind(''), isNull);
  });
}
