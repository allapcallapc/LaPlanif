import 'package:fetch_api/fetch_api.dart';

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
    final response = await fetch(
      url,
      FetchOptions(method: 'HEAD', mode: RequestMode.cors, redirect: RequestRedirect.follow),
    ).timeout(timeout);
    final finalUrl = response.url;
    return finalUrl.isEmpty ? null : finalUrl;
  } catch (_) {
    return null;
  }
}
