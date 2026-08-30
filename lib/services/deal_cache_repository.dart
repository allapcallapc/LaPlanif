import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/deal_item.dart';

/// Persists the last successfully fetched flyer items, so reopening the
/// Planif screen shows them immediately instead of requiring another fetch.
/// Cleared whenever the user explicitly asks to reload.
class DealCacheRepository {
  static const _prefsKey = 'deal_cache';
  static const _fetchedAtKey = 'deal_cache_fetched_at';

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

  /// When the cached items were fetched, or null if there's no cache - or
  /// the cache predates this field (an old save() never recorded one).
  Future<DateTime?> loadFetchedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getInt(_fetchedAtKey);
    if (raw == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(raw);
  }

  Future<void> save(List<DealItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(items.map((item) => item.toJson()).toList()));
    await prefs.setInt(_fetchedAtKey, DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    await prefs.remove(_fetchedAtKey);
  }
}
