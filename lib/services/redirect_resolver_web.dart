import 'dart:js_interop';

/// Hand-written, minimal Fetch API binding - just enough to make a
/// cross-origin HEAD request and read the resolved URL after any redirects.
///
/// Deliberately built directly on `dart:js_interop` (part of the Dart SDK
/// itself, so it can never be version-skewed against it) rather than
/// `package:web` or a third-party fetch-wrapper package: both pulled in
/// unrelated internal helper code (event-stream plumbing, JS iterator
/// protocol support, etc.) that didn't compile against this project's Dart
/// SDK version, for functionality this file doesn't even use.
@JS('fetch')
external JSPromise<_FetchResponse> _fetch(JSString input, _FetchInit init);

extension type _FetchInit._(JSObject _) implements JSObject {
  external factory _FetchInit({String method, String mode, String redirect});
}

extension type _FetchResponse._(JSObject _) implements JSObject {
  external JSString get url;
}

/// Follows [url]'s HTTP redirect chain via the browser's `fetch()` API and
/// returns the final destination URL, or null if it can't be determined.
///
/// This exists for one reason: Google Search grounding's
/// `groundingChunks[].web.uri` is always an opaque
/// `vertexaisearch.cloud.google.com/grounding-api-redirect/...` link, never
/// the real recipe page URL (see MealPlanGenerationService's doc comment).
/// `package:http`, used everywhere else in this app, has no cross-platform
/// way to read the final URL after a redirect - see
/// https://github.com/dart-lang/http/issues/293 - so this bypasses it and
/// calls the raw Fetch API directly, whose `Response.url` does carry it, but
/// only when the request is made with `mode: cors` (fetch's own default is
/// `no-cors`, which always yields an opaque, unreadable response).
///
/// Resolving this way only works if the redirect target sends back
/// `Access-Control-Allow-Origin` for this page's origin - Google's redirect
/// endpoint isn't a public API, so there's no guarantee it does. When it
/// doesn't (or the request fails or times out for any other reason), this
/// returns null and the caller is expected to fall back to the original
/// redirect link, which always works as a plain link even when it can't be
/// read as text.
Future<String?> resolveRedirectUrl(String url, {Duration timeout = const Duration(seconds: 6)}) async {
  try {
    final init = _FetchInit(method: 'HEAD', mode: 'cors', redirect: 'follow');
    final response = await _fetch(url.toJS, init).toDart.timeout(timeout);
    final finalUrl = response.url.toDart;
    return finalUrl.isEmpty ? null : finalUrl;
  } catch (_) {
    return null;
  }
}
