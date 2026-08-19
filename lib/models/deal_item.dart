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

  /// Flyer items don't have a stable ID, so store+name stands in for one
  /// when persisting a preference across re-fetches of the same flyer.
  String get preferenceKey => '$storeName::$name';

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
