enum DealCategory { protein, carbs, vegetables, uncategorized }

/// Buckets an item name into a category by keyword match.
///
/// Checked in this order - protein, then carbs, then vegetables - so an
/// item matching more than one group (e.g. a name containing both a
/// protein and a carbs keyword) lands in the earlier group. Anything
/// matching none of the three is uncategorized rather than forced into a
/// bucket it doesn't belong in.
class ItemCategorizer {
  static const _proteinKeywords = [
    'poulet',
    'volaille',
    'dinde',
    'boeuf',
    'steak',
    'bavette',
    'haché',
    'porc',
    'jambon',
    'bacon',
    'côtelette',
    'saumon',
    'poisson',
    'crevette',
    'tilapia',
    'morue',
    'truite',
    'tofu',
    'oeuf',
    'œuf',
    'fromage',
    'haricot',
    'fève',
    'lentille',
    'pois chiche',
    'charcuterie',
    'saucisse',
  ];

  static const _carbsKeywords = [
    'pâtes',
    'pasta',
    'spaghetti',
    'macaroni',
    'riz',
    'pain',
    'baguette',
    'patate',
    'pomme de terre',
    'céréale',
    'farine',
    'tortilla',
    'couscous',
    'quinoa',
    'bagel',
    'craquelin',
  ];

  static const _vegetableKeywords = [
    'brocoli',
    'carotte',
    'poivron',
    'tomate',
    'laitue',
    'salade',
    'concombre',
    'chou',
    'maïs',
    'avocat',
    'oignon',
    'champignon',
    'épinard',
    'courgette',
    'asperge',
    'betterave',
    'céleri',
    'fruit',
    'pomme',
    'banane',
    'orange',
    'raisin',
    'fraise',
    'bleuet',
  ];

  static DealCategory categorize(String name) {
    final lower = name.toLowerCase();
    if (_proteinKeywords.any(lower.contains)) return DealCategory.protein;
    if (_carbsKeywords.any(lower.contains)) return DealCategory.carbs;
    if (_vegetableKeywords.any(lower.contains)) return DealCategory.vegetables;
    return DealCategory.uncategorized;
  }
}
