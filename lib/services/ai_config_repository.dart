import 'package:shared_preferences/shared_preferences.dart';

/// Stores the user's own Anthropic API key locally (this browser only).
/// There is no default - the key must be entered in Config before any AI
/// extraction call can be made.
class AiConfigRepository {
  static const _apiKeyPrefsKey = 'ai_api_key';

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
}
