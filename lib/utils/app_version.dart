/// The app version, injected at build time by the deploy workflows via
/// `--dart-define=APP_VERSION=...` (the same value they pass to
/// `--build-name`: e.g. `0.4.0` for a release, `0.4.0-main-abc1234` for the
/// /main/ preview, `0.4.0-pr12-abc1234` for a PR preview). Falls back to
/// `dev` for local `flutter run` builds where no define is passed.
const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
