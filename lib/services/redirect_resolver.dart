/// Resolves Google Search grounding's opaque redirect links to their real
/// destination URL - see redirect_resolver_web.dart for how and why that
/// works (or doesn't - it's best-effort). Conditionally exported rather
/// than imported directly: `dart:js_interop`, which the web implementation
/// needs, isn't an available library on the Dart VM, and `flutter test`
/// runs on the VM rather than a real browser - so VM-run tests get
/// redirect_resolver_stub.dart's no-op instead, and never even try to
/// compile the web-only file.
export 'redirect_resolver_stub.dart' if (dart.library.js_interop) 'redirect_resolver_web.dart';
