import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/store_config.dart';

class StoreConfigRepository {
  static const _prefsKey = 'store_configs';

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
  ];

  Future<List<StoreConfig>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        return decoded.map((e) => StoreConfig.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        // Leftover data from an older, incompatible schema - reseed below.
      }
    }
    final defaults = defaultStores();
    await save(defaults);
    return defaults.toList();
  }

  Future<void> save(List<StoreConfig> stores) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(stores.map((s) => s.toJson()).toList());
    await prefs.setString(_prefsKey, raw);
  }
}
