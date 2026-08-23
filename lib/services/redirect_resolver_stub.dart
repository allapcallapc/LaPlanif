/// Fallback for any platform where `dart:js_interop` doesn't exist. This app
/// only ever ships for web, but `flutter test` still runs on the Dart VM
/// (not a browser), where `dart:js_interop` isn't an available library at
/// all - see redirect_resolver.dart's conditional export.
///
/// Always returns null ("couldn't resolve, keep the original redirect
/// link"), the same as MealPlanGenerationService's own default already
/// does when no resolver is injected at all - so a test run behaves exactly
/// like the no-resolver case, never touching a real browser API.
Future<String?> resolveRedirectUrl(String url, {Duration timeout = const Duration(seconds: 6)}) async => null;
