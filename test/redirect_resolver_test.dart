import 'package:flutter_test/flutter_test.dart';

import 'package:laplanif/services/redirect_resolver.dart';

void main() {
  // flutter test runs on the Dart VM, where dart:js_interop doesn't exist -
  // redirect_resolver.dart's conditional export resolves to
  // redirect_resolver_stub.dart here, never the real dart:js_interop-based
  // implementation in redirect_resolver_web.dart (which only compiles for
  // web/wasm targets, and so is untouched by this test run entirely).
  test('resolveRedirectUrl is a no-op on the Dart VM', () async {
    expect(await resolveRedirectUrl('https://example.com/redirect'), isNull);
  });
}
