import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/deal_item.dart';

/// Persists per-item preferences (neutral/priority/excluded), keyed by
/// [DealItem.preferenceKey], so selections survive re-fetching the same
/// flyer items later. Neutral is the default and isn't stored, so the map
/// only ever holds priority/excluded entries.
class DealPreferenceRepository {
  static const _prefsKey = 'deal_preferences';

  Future<Map<String, DealPreference>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((key, value) => MapEntry(key, _fromName(value as String)));
    } catch (_) {
      return const {};
    }
  }

  Future<void> setPreference(String key, DealPreference preference) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final current = <String, dynamic>{};
    if (raw != null) {
      try {
        current.addAll(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        // Leftover data from an older, incompatible schema - reseed below.
      }
    }
    if (preference == DealPreference.neutral) {
      current.remove(key);
    } else {
      current[key] = preference.name;
    }
    await prefs.setString(_prefsKey, jsonEncode(current));
  }

  DealPreference _fromName(String name) =>
      DealPreference.values.firstWhere((p) => p.name == name, orElse: () => DealPreference.neutral);
}
