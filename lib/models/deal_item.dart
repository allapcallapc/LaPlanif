enum DealCategory { protein, vegetables, carbs, uncategorized }

extension DealCategoryLabel on DealCategory {
  String get label => switch (this) {
    DealCategory.protein => 'Protein',
    DealCategory.vegetables => 'Vegetables',
    DealCategory.carbs => 'Carbs',
    DealCategory.uncategorized => 'Uncategorized',
  };

  static DealCategory fromLabel(String label) => switch (label.trim().toLowerCase()) {
    'protein' => DealCategory.protein,
    'vegetables' => DealCategory.vegetables,
    'carbs' => DealCategory.carbs,
    _ => DealCategory.uncategorized,
  };
}

enum DealPreference { neutral, priority, excluded }

extension DealPreferenceCycle on DealPreference {
  /// Tap order: neutral -> priority -> excluded -> neutral.
  DealPreference get next => switch (this) {
    DealPreference.neutral => DealPreference.priority,
    DealPreference.priority => DealPreference.excluded,
    DealPreference.excluded => DealPreference.neutral,
  };
}

class DealItem {
  const DealItem({
    required this.name,
    required this.price,
    required this.unit,
    required this.category,
    required this.storeName,
    required this.pageIndex,
    this.preference = DealPreference.neutral,
  });

  final String name;
  final String price;

  /// The unit the price applies to (e.g. "lb", "kg", "100g"), or an empty
  /// string when it's a flat price rather than a per-unit one.
  final String unit;
  final DealCategory category;
  final String storeName;
  final int pageIndex;
  final DealPreference preference;

  /// Page 1 is always the flyer's cover page, by convention of how pages
  /// are numbered when sent for extraction.
  bool get isCoverPage => pageIndex == 1;

  /// Display-ready price, with the unit appended when the price is per-unit
  /// rather than flat.
  String get priceText => unit.isEmpty ? price : '$price/$unit';

  /// Flyer items don't have a stable ID, so store+name+price+unit stands in
  /// for one when persisting a preference across re-fetches of the same
  /// flyer. Price and unit are included because a flyer can list the same
  /// product name more than once at different prices (e.g. whole chicken vs.
  /// chicken thighs both named "Poulet") - name alone would collapse those
  /// into a single persisted preference.
  String get preferenceKey => '$storeName::$name::$price::$unit';

  DealItem copyWith({DealPreference? preference}) => DealItem(
    name: name,
    price: price,
    unit: unit,
    category: category,
    storeName: storeName,
    pageIndex: pageIndex,
    preference: preference ?? this.preference,
  );
}
