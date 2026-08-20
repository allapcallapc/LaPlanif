import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/meal_history.dart';

class MealHistoryRepository {
  static const _prefsKey = 'meal_history';

  /// All saved weeks, most recent first. Unlike [StoreConfigRepository] /
  /// [MealPlanConfigRepository], history starts genuinely empty rather than
  /// seeded with defaults - nothing is saved until the user explicitly saves
  /// a week's plan.
  Future<List<MealHistoryEntry>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final entries = decoded.map((e) => MealHistoryEntry.fromJson(e as Map<String, dynamic>)).toList();
      // Lexicographic order on "YYYY-Www" matches chronological order (W is
      // always zero-padded), so a plain string sort is enough.
      entries.sort((a, b) => b.weekId.compareTo(a.weekId));
      return entries;
    } catch (_) {
      // Leftover data from an older, incompatible schema - treat as empty
      // rather than surfacing a parse error to the user.
      return [];
    }
  }

  /// Writes [entry], overwriting any existing entry for the same
  /// [MealHistoryEntry.weekId] - one plan per week, always.
  Future<void> saveWeek(MealHistoryEntry entry) async {
    final all = await loadAll();
    final without = all.where((e) => e.weekId != entry.weekId).toList();
    await _persist([...without, entry]);
  }

  Future<void> deleteWeek(String weekId) async {
    final all = await loadAll();
    await _persist(all.where((e) => e.weekId != weekId).toList());
  }

  /// Every (recipe, deal items) pairing from a saved week whose [savedAt]
  /// falls within [diversityWindowDays] of [now] - a soft "recently used,
  /// try to vary" hint for preview generation. Weeks fully outside the
  /// window are dropped here but remain visible in the History screen, since
  /// this only affects what gets passed into generation.
  Future<List<RecentHistoryItem>> recentlyUsed({required int diversityWindowDays, DateTime? now}) async {
    final cutoff = (now ?? DateTime.now()).subtract(Duration(days: diversityWindowDays));
    final all = await loadAll();
    return [
      for (final entry in all)
        if (!entry.savedAt.isBefore(cutoff))
          for (final slot in entry.slots) RecentHistoryItem(recipeName: slot.recipeName, dealItemsUsed: slot.dealItemsUsed),
    ];
  }

  Future<void> _persist(List<MealHistoryEntry> entries) async {
    entries.sort((a, b) => b.weekId.compareTo(a.weekId));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(entries.map((e) => e.toJson()).toList()));
  }
}
