/// The app version, injected at build time by the deploy workflows via
/// `--dart-define=APP_VERSION=...`. Releases use the plain version (e.g.
/// `0.4.0`); previews use semver build metadata, since they're newer than
/// that version rather than a pre-release of it: `0.4.0+main.abc1234` for
/// /main/, `0.4.0+pr12.abc1234` for a PR preview. Falls back to `dev` for
/// local builds where no define is passed.
const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
