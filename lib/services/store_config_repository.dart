import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/store_config.dart';

class StoreConfigRepository {
  static const _prefsKey = 'store_configs';

  /// Ids of default stores the user has already been given. Lets a default
  /// added in a later version (e.g. Super C) be appended once to an existing
  /// saved list, without re-adding a default the user has since deleted.
  static const _seededIdsPrefsKey = 'store_configs_seeded_default_ids';

  /// Defaults every saved list predating [_seededIdsPrefsKey] was seeded with.
  static const _originalDefaultIds = ['iga', 'metro', 'maxi'];

  static List<StoreConfig> defaultStores() => const [
    StoreConfig(
      id: 'iga',
      name: 'IGA',
      flyerUrl: 'https://www.circulaire-en-ligne.ca/circulaire-iga-epicerie/speciaux-promotions-rabais-semaine',
    ),
    StoreConfig(
      id: 'metro',
      name: 'Metro',
      flyerUrl:
          'https://www.circulaire-en-ligne.ca/circulaire-metro/circulaire-metro-speciaux-promotions-et-rabais-de-cette-semaine',
    ),
    StoreConfig(
      id: 'maxi',
      name: 'Maxi',
      flyerUrl: 'https://www.circulaire-en-ligne.ca/circulaire-maxi/speciaux-promotions-rabais-semaine',
    ),
    StoreConfig(
      id: 'super-c',
      name: 'Super C',
      flyerUrl: 'https://www.circulaire-en-ligne.ca/circulaire-super-c/circulaire-semaine-super-c',
    ),
  ];

  Future<List<StoreConfig>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      List<StoreConfig>? stores;
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        stores = decoded.map((e) => StoreConfig.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        // Leftover data from an older, incompatible schema - reseed below.
      }
      // Outside the try: a failed write here must not fall into the reseed
      // path, which would overwrite the user's saved stores with defaults.
      if (stores != null) return _appendNewDefaults(prefs, stores);
    }
    final defaults = defaultStores();
    await save(defaults);
    await prefs.setStringList(_seededIdsPrefsKey, defaults.map((s) => s.id).toList());
    return defaults.toList();
  }

  Future<List<StoreConfig>> _appendNewDefaults(SharedPreferences prefs, List<StoreConfig> stores) async {
    final seeded = prefs.getStringList(_seededIdsPrefsKey) ?? _originalDefaultIds;
    // Also match by name: a store the user added by hand gets a timestamp id,
    // and duplicate names break the per-store retry in planif_screen.
    final existingIds = stores.map((s) => s.id).toSet();
    final existingNames = stores.map((s) => s.name.toLowerCase()).toSet();
    final newDefaults = defaultStores().where(
      (d) => !seeded.contains(d.id) && !existingIds.contains(d.id) && !existingNames.contains(d.name.toLowerCase()),
    );
    final allDefaultIds = defaultStores().map((s) => s.id);
    if (newDefaults.isEmpty && allDefaultIds.every(seeded.contains)) return stores;
    stores.addAll(newDefaults);
    await save(stores);
    await prefs.setStringList(_seededIdsPrefsKey, {...seeded, ...allDefaultIds}.toList());
    return stores;
  }

  Future<void> save(List<StoreConfig> stores) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(stores.map((s) => s.toJson()).toList());
    await prefs.setString(_prefsKey, raw);
  }
}
