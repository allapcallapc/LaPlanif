/// A rough grocery-aisle grouping for shopping-list ingredients, used only to
/// cluster the list into a walkable order. Distinct from [DealCategory] (see
/// `models/deal_item.dart`), which classifies flyer deal items into a much
/// coarser set of buckets for meal-plan generation.
enum GroceryCategory {
  produce,
  meatAndSeafood,
  dairyAndEggs,
  bakery,
  pantry,
  frozen,
  other;

  String get label => switch (this) {
    GroceryCategory.produce => 'Produce',
    GroceryCategory.meatAndSeafood => 'Meat & Seafood',
    GroceryCategory.dairyAndEggs => 'Dairy & Eggs',
    GroceryCategory.bakery => 'Bakery',
    GroceryCategory.pantry => 'Pantry',
    GroceryCategory.frozen => 'Frozen',
    GroceryCategory.other => 'Other',
  };
}

/// Category -> matching keywords, checked in this order (not display order -
/// see [GroceryCategory.values] for that) so a more specific phrase from an
/// earlier category (e.g. pantry's "black pepper") wins over a broader
/// keyword from a later one that would otherwise also match the same text
/// (e.g. produce's bare "pepper", which should catch "bell pepper" instead).
const _categoryKeywords = <GroceryCategory, List<String>>{
  GroceryCategory.meatAndSeafood: [
    'chicken', 'beef', 'pork', 'turkey', 'bacon', 'sausage', 'ham', 'steak',
    'fish', 'salmon', 'shrimp', 'tuna', 'meat', 'lamb', 'veal', 'tofu',
    'tilapia', 'cod', 'crab', 'lobster', 'prawn',
  ],
  GroceryCategory.dairyAndEggs: [
    'milk', 'cheese', 'yogurt', 'yoghurt', 'butter', 'cream', 'egg',
    'mozzarella', 'cheddar', 'parmesan', 'feta', 'ricotta',
  ],
  GroceryCategory.bakery: ['bread', 'bun', 'bagel', 'tortilla', 'roll', 'pita', 'naan', 'baguette'],
  GroceryCategory.pantry: [
    'rice', 'pasta', 'noodle', 'flour', 'sugar', 'oil', 'vinegar', 'sauce',
    'broth', 'stock', 'spice', 'salt', 'black pepper', 'white pepper',
    'cayenne pepper', 'pepper flakes', 'ground pepper', 'peppercorn',
    'cumin', 'paprika', 'cinnamon', 'oregano', 'bean', 'lentil', 'chickpea',
    'cereal', 'oat', 'honey', 'syrup', 'ketchup', 'mustard', 'mayo',
    'breadcrumb', 'cornstarch', 'baking powder', 'baking soda', 'nut',
    'seed', 'canned', 'can of', 'jam', 'jelly',
  ],
  GroceryCategory.frozen: ['frozen', 'ice cream'],
  GroceryCategory.produce: [
    'onion', 'garlic', 'tomato', 'potato', 'broccoli', 'carrot', 'pepper',
    'lettuce', 'spinach', 'cucumber', 'zucchini', 'mushroom', 'celery',
    'cabbage', 'kale', 'avocado', 'lemon', 'lime', 'apple', 'banana',
    'berry', 'berries', 'cilantro', 'parsley', 'basil', 'ginger', 'scallion',
    'green onion', 'corn', 'squash', 'fruit', 'vegetable', 'salad', 'herb',
  ],
};

/// Buckets a free-form ingredient name (e.g. "boneless skinless chicken
/// breasts") into a [GroceryCategory] by keyword match, falling back to
/// [GroceryCategory.other] when nothing matches. Deterministic and offline -
/// no AI call, so it's stable across weeks even when the AI's own wording
/// for the same ingredient isn't.
GroceryCategory categorizeIngredient(String name) {
  final lower = name.toLowerCase();
  for (final entry in _categoryKeywords.entries) {
    if (entry.value.any(lower.contains)) return entry.key;
  }
  return GroceryCategory.other;
}
