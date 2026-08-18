class StoreConfig {
  const StoreConfig({required this.id, required this.name, required this.flyerUrl});

  final String id;
  final String name;

  /// The store's weekly-deals page on circulaire-en-ligne.ca.
  ///
  /// Stored verbatim rather than assembled from a slug: the final path
  /// segment isn't actually consistent across stores (e.g. Metro's is
  /// "circulaire-metro-speciaux-promotions-et-rabais-de-cette-semaine",
  /// not the generic "speciaux-promotions-rabais-semaine" other stores use).
  final String flyerUrl;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'flyerUrl': flyerUrl};

  factory StoreConfig.fromJson(Map<String, dynamic> json) => StoreConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    flyerUrl: json['flyerUrl'] as String,
  );
}
