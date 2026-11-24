/// What kind of ingredient a deal or pantry item is, so two meals using
/// "Riz Jasmin Dainty" and "Basmati rice", or chicken thighs and chicken
/// breasts, can be recognized as repeating the same thing. Flyer names mix
/// French and English, brands, formats and cuts, so this matches on word
/// stems in both languages rather than on the exact name.
///
/// Returns null for an ingredient none of the known kinds covers - such an
/// item is then only ever compared by its exact name.
String? ingredientKind(String name) {
  final text = ' ${_normalize(name)} ';
  for (final (kind, stems) in _kinds) {
    for (final stem in stems) {
      if (text.contains(' $stem')) return kind;
    }
  }
  return null;
}

String _normalize(String name) {
  const accents = {
    'à': 'a', 'â': 'a', 'ä': 'a', 'á': 'a', 'ç': 'c', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', //
    'î': 'i', 'ï': 'i', 'í': 'i', 'ô': 'o', 'ö': 'o', 'ó': 'o', 'œ': 'oe', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ú': 'u',
  };
  final lower = name.toLowerCase();
  final buffer = StringBuffer();
  for (final char in lower.split('')) {
    final plain = accents[char] ?? char;
    buffer.write(RegExp(r'[a-z0-9]').hasMatch(plain) || plain.length > 1 ? plain : ' ');
  }
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

// Checked in order, so the more specific kinds come first: "sweet potato"
// before "potato", "rice noodles" before "rice", "ground pork" is pork.
// Each stem must start a word ("riz" matches "riz basmati", not "ariz"); a
// stem ending in a space must also end one ("rice " skips "ricotta").
const List<(String, List<String>)> _kinds = [
  // Carbs
  ('sweet potato', ['sweet potato', 'patate douce', 'patates douces']),
  ('noodles', ['noodle', 'nouille', 'vermicelle', 'ramen', 'udon', 'soba']),
  ('rice', ['riz', 'rice ', 'rices', 'basmati', 'jasmin', 'arborio', 'risotto']),
  (
    'pasta',
    [
      'pasta',
      'pate alimentaire',
      'pates alimentaires',
      'pates',
      'spaghetti',
      'penne',
      'fusilli',
      'macaroni',
      'linguine',
      'fettuccine',
      'rigatoni',
      'orzo',
      'lasagn',
      'tortellini',
      'ravioli',
      'gnocchi',
      'rotini',
      'farfalle',
    ],
  ),
  ('potato', ['potato', 'pomme de terre', 'pommes de terre', 'patate', 'grelot', 'frites', 'fries']),
  ('couscous', ['couscous']),
  ('quinoa', ['quinoa']),
  ('bulgur', ['bulgur', 'boulgour']),
  ('barley', ['barley', 'orge']),
  ('bread', ['bread', 'pain ', 'pains', 'baguette', 'naan', 'pita ', 'bagel', 'brioche', 'bun ', 'buns']),
  ('tortilla', ['tortilla', 'wrap']),
  // Proteins - by animal (or plant protein), whatever the cut.
  ('chicken', ['chicken', 'poulet', 'volaille', 'pilon', 'haut de cuisse', 'hauts de cuisse']),
  ('turkey', ['turkey', 'dinde']),
  ('pork', ['pork', 'porc', 'jambon', 'ham ', 'bacon', 'lardon', 'cotes levees', 'cote levee']),
  ('beef', ['beef', 'boeuf', 'steak', 'bavette', 'surlonge', 'contre filet']),
  ('veal', ['veal', 'veau']),
  ('lamb', ['lamb', 'agneau']),
  ('salmon', ['salmon', 'saumon']),
  ('tuna', ['tuna', 'thon']),
  ('cod', ['cod ', 'morue', 'cabillaud']),
  ('tilapia', ['tilapia']),
  ('trout', ['trout', 'truite']),
  ('shrimp', ['shrimp', 'crevette', 'prawn']),
  ('tofu', ['tofu']),
  ('egg', ['egg ', 'eggs', 'oeuf']),
  ('chickpeas', ['chickpea', 'pois chiche']),
  ('lentils', ['lentil', 'lentille']),
  // Vegetables
  ('broccoli', ['broccoli', 'brocoli']),
  ('cauliflower', ['cauliflower', 'chou fleur', 'choux fleurs']),
  ('brussels sprouts', ['brussels sprout', 'chou de bruxelles', 'choux de bruxelles']),
  ('bok choy', ['bok choy', 'pak choi', 'bok choi']),
  ('kale', ['kale', 'chou frise']),
  ('cabbage', ['cabbage', 'chou ', 'choux ']),
  ('carrot', ['carrot', 'carotte']),
  ('green beans', ['green bean', 'haricot vert', 'haricots verts']),
  ('pepper', ['bell pepper', 'pepper ', 'peppers', 'poivron']),
  ('asparagus', ['asparagus', 'asperge']),
  ('zucchini', ['zucchini', 'courgette']),
  ('squash', ['squash', 'courge', 'butternut']),
  ('spinach', ['spinach', 'epinard']),
  ('peas', ['green pea', 'peas ', 'petits pois', 'petit pois', 'pois ']),
  ('corn', ['corn ', 'mais ']),
  ('mushroom', ['mushroom', 'champignon']),
  ('tomato', ['tomato', 'tomate']),
  ('eggplant', ['eggplant', 'aubergine']),
  ('lettuce', ['lettuce', 'laitue', 'romaine', 'salad', 'salade']),
  ('cucumber', ['cucumber', 'concombre']),
  ('leek', ['leek', 'poireau']),
  ('celery', ['celery', 'celeri']),
  ('onion', ['onion', 'oignon']),
];
