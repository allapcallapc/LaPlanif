class StoreConfig {
  const StoreConfig({
    required this.id,
    required this.name,
    required this.slug,
    this.useEpicerieVariant = false,
  });

  final String id;
  final String name;
  final String slug;
  final bool useEpicerieVariant;

  /// The store's weekly-deals page on circulaire-en-ligne.ca.
  String get flyerUrl {
    final path = useEpicerieVariant ? 'circulaire-$slug-epicerie' : 'circulaire-$slug';
    return 'https://www.circulaire-en-ligne.ca/$path/speciaux-promotions-rabais-semaine';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'slug': slug,
    'useEpicerieVariant': useEpicerieVariant,
  };

  factory StoreConfig.fromJson(Map<String, dynamic> json) => StoreConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    slug: json['slug'] as String,
    useEpicerieVariant: json['useEpicerieVariant'] as bool? ?? false,
  );
}
