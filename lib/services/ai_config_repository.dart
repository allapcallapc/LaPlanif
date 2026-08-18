import 'package:shared_preferences/shared_preferences.dart';

/// Stores the user's own Google AI (Gemini) API key and the ordered list of
/// models to try, all locally (this browser only). There is no default key -
/// it must be entered in Config before any AI extraction call can be made.
class AiConfigRepository {
  static const _apiKeyPrefsKey = 'ai_api_key';
  static const _modelsPrefsKey = 'ai_models';

  /// Used whenever no model list has been configured yet.
  static const defaultModels = ['gemini-3.6-flash'];

  Future<String> loadApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_apiKeyPrefsKey) ?? '';
  }

  Future<void> saveApiKey(String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = apiKey.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(_apiKeyPrefsKey);
    } else {
      await prefs.setString(_apiKeyPrefsKey, trimmed);
    }
  }

  Future<List<String>> loadModels() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_modelsPrefsKey);
    if (stored == null || stored.isEmpty) return List.of(defaultModels);
    return stored;
  }

  Future<void> saveModels(List<String> models) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = models.map((m) => m.trim()).where((m) => m.isNotEmpty).toList();
    if (trimmed.isEmpty) {
      await prefs.remove(_modelsPrefsKey);
    } else {
      await prefs.setStringList(_modelsPrefsKey, trimmed);
    }
  }
}
