import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/store_config.dart';

class StoreConfigRepository {
  static const _prefsKey = 'store_configs';

  static List<StoreConfig> defaultStores() => const [
    StoreConfig(id: 'iga', name: 'IGA', slug: 'iga', useEpicerieVariant: true),
    StoreConfig(id: 'metro', name: 'Metro', slug: 'metro'),
    StoreConfig(id: 'maxi', name: 'Maxi', slug: 'maxi'),
  ];

  Future<List<StoreConfig>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) {
      final defaults = defaultStores();
      await save(defaults);
      return defaults.toList();
    }
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded.map((e) => StoreConfig.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> save(List<StoreConfig> stores) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(stores.map((s) => s.toJson()).toList());
    await prefs.setString(_prefsKey, raw);
  }
}
