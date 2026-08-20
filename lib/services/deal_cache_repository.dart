import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/deal_item.dart';

/// Persists the last successfully fetched flyer items, so reopening the
/// Planif screen shows them immediately instead of requiring another fetch.
/// Cleared whenever the user explicitly asks to reload.
class DealCacheRepository {
  static const _prefsKey = 'deal_cache';

  Future<List<DealItem>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((e) => DealItem.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<DealItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(items.map((item) => item.toJson()).toList()));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
