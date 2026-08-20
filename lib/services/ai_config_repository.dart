import 'package:shared_preferences/shared_preferences.dart';

/// Stores the user's own Google AI (Gemini) API key and the ordered list of
/// models to try, all locally (this browser only). There is no default key -
/// it must be entered in Config before any AI extraction call can be made.
class AiConfigRepository {
  static const _apiKeyPrefsKey = 'ai_api_key';
  static const _modelsPrefsKey = 'ai_models';
  static const _groundingModelsPrefsKey = 'ai_grounding_models';

  /// Used whenever no model list has been configured yet. Tried in order -
  /// gemini-3.5-flash-lite first, then a specific hand-picked fallback
  /// order (not a strict newest-to-oldest sort).
  static const defaultModels = [
    'gemini-3.5-flash-lite',
    'gemini-3.5-flash',
    'gemini-3.6-flash',
    'gemini-3.7-flash',
    'gemini-3.1-flash-lite',
    'gemini-3-flash',
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
  ];

  /// Used whenever no grounding-model list has been configured yet, for the
  /// meal-plan generation step's search-grounded recipe lookup. Defaults to
  /// the same list as [defaultModels] - grounding support and free-tier
  /// availability can vary by account, so this exists as a separately
  /// configurable override for whoever hits a model that doesn't work for
  /// them, not because any particular family is assumed broken by default.
  static const defaultGroundingModels = defaultModels;

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

  Future<List<String>> loadGroundingModels() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_groundingModelsPrefsKey);
    if (stored == null || stored.isEmpty) return List.of(defaultGroundingModels);
    return stored;
  }

  Future<void> saveGroundingModels(List<String> models) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = models.map((m) => m.trim()).where((m) => m.isNotEmpty).toList();
    if (trimmed.isEmpty) {
      await prefs.remove(_groundingModelsPrefsKey);
    } else {
      await prefs.setStringList(_groundingModelsPrefsKey, trimmed);
    }
  }
}
