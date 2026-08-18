import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_call_log.dart';

/// Persists a record of every AI extraction call made, newest first, so
/// they can be reviewed on the AI usage screen.
class AiCallLogRepository {
  static const _prefsKey = 'ai_call_logs';
  static const _maxEntries = 200;

  Future<List<AiCallLog>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((e) => AiCallLog.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> add(AiCallLog log) async {
    final existing = await loadAll();
    final updated = [log, ...existing].take(_maxEntries).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(updated.map((l) => l.toJson()).toList()));
  }
}
