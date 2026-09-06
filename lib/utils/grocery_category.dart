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

/// Category -> matching keywords. Checking order no longer matters here (see
/// [_rankedKeywords]) - a keyword's specificity, not which category happens
/// to list it, decides which wins when more than one would otherwise match.
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
    'green onion', 'green bean', 'eggplant', 'corn', 'squash', 'fruit',
    'vegetable', 'salad', 'herb',
  ],
};

/// Every (category, keyword) pair, sorted with the most specific keywords
/// (the most words) first. A compound phrase always wins over a shorter one
/// nested inside it regardless of which category happens to list it - e.g.
/// pantry's two-word "black pepper" is checked before produce's bare
/// "pepper" (which should catch "bell pepper" instead), and frozen's
/// two-word "ice cream" before dairy's bare "cream" - without needing the
/// two categories' relative order in [_categoryKeywords] to encode that.
final List<(GroceryCategory, String)> _rankedKeywords =
    [for (final entry in _categoryKeywords.entries) for (final keyword in entry.value) (entry.key, keyword)]
      ..sort((a, b) => b.$2.split(' ').length.compareTo(a.$2.split(' ').length));

/// Splits free-form text into lowercase word tokens, e.g. "Boneless,
/// skinless chicken breasts" -> ['boneless', 'skinless', 'chicken',
/// 'breasts'].
List<String> _wordsOf(String text) => text.toLowerCase().split(RegExp(r'[^a-z]+')).where((w) => w.isNotEmpty).toList();

/// Strips a trailing "s" off simple plurals (e.g. "breasts" -> "breast") so
/// keyword matching isn't defeated by pluralization. Deliberately naive -
/// only used to compare whole words, never to look inside a longer word.
String _singularize(String word) => word.length > 3 && word.endsWith('s') ? word.substring(0, word.length - 1) : word;

/// Whether [keyword] (one or more words, e.g. "black pepper") appears as a
/// contiguous run of whole words inside [nameWords] - not merely as a
/// substring, so "egg" doesn't match inside "eggplant" and "ham" doesn't
/// match inside "hamburger".
bool _matchesKeyword(List<String> nameWords, String keyword) {
  final keywordWords = keyword.split(' ').map(_singularize).toList();
  for (var start = 0; start + keywordWords.length <= nameWords.length; start++) {
    var matchesHere = true;
    for (var offset = 0; offset < keywordWords.length; offset++) {
      if (_singularize(nameWords[start + offset]) != keywordWords[offset]) {
        matchesHere = false;
        break;
      }
    }
    if (matchesHere) return true;
  }
  return false;
}

/// Buckets a free-form ingredient name (e.g. "boneless skinless chicken
/// breasts") into a [GroceryCategory] by whole-word keyword match (see
/// [_matchesKeyword] - never a raw substring check, which would wrongly
/// catch e.g. "egg" inside "eggplant"), falling back to [GroceryCategory.
/// other] when nothing matches. Deterministic and offline - no AI call, so
/// it's stable across weeks even when the AI's own wording for the same
/// ingredient isn't.
GroceryCategory categorizeIngredient(String name) {
  final words = _wordsOf(name);
  for (final (category, keyword) in _rankedKeywords) {
    if (_matchesKeyword(words, keyword)) return category;
  }
  return GroceryCategory.other;
}
