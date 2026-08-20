import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/screens/planif_screen.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Records the last URL/options handed to the platform, standing in for the
/// real platform-channel implementation url_launcher would otherwise use.
class _FakeUrlLauncherPlatform extends UrlLauncherPlatform {
  String? launchedUrl;
  LaunchOptions? launchedOptions;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launchedUrl = url;
    launchedOptions = options;
    return true;
  }
}

void main() {
  test('openRecipeLink hands the URL to the platform launcher as an external application', () async {
    final fake = _FakeUrlLauncherPlatform();
    final original = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = fake;
    addTearDown(() => UrlLauncherPlatform.instance = original);

    await openRecipeLink(Uri.parse('https://example.com/pulled-pork'));

    expect(fake.launchedUrl, 'https://example.com/pulled-pork');
    expect(fake.launchedOptions?.mode, PreferredLaunchMode.externalApplication);
  });
}
